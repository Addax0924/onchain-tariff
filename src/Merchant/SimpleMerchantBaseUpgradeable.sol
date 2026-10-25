// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "../interfaces/IMarket.sol";
import "../interfaces/IMerchantTradeIn.sol";
import "../interfaces/ISettlementAsset.sol";

/// @notice One Account Owner, one Market account, and one fixed capacity tier.
/// @dev The first successful sale binds the account ID. A later registration needs a new proxy,
///      so old release allowances cannot be reused by a new Market account.
abstract contract SimpleMerchantBase is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
    IMerchantTradeIn
{
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10000;

    IMarket public market;
    IERC20 public underlying;
    address public settlementAsset;
    address public tradeExecutor;
    address public business;
    address public accountOwner;
    uint256 public capacityMultiplier;
    uint256 public accountId;

    uint256 public ownerShareBps;
    uint256 public businessShareBps;
    uint256 public received;
    uint256 public ownerReleased;
    uint256 public businessReleased;

    event TradeExecutorUpdated(address indexed oldTradeExecutor, address indexed newTradeExecutor);
    event BusinessUpdated(address indexed oldBusiness, address indexed newBusiness);
    event SaleRecorded(uint256 indexed accountId, uint160 indexed rechargeTarget, uint256 netAmount, uint256 deltaW);
    event OwnerReleaseRecorded(uint256 indexed accountId, uint256 amount);
    event OwnerShareDeposited(uint256 indexed accountId, uint256 amount);
    event BusinessReleaseRecorded(uint256 indexed accountId, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    /// @dev A derived proxy initializer calls this once. The Account Owner is the initial administrator.
    function __SimpleMerchantBase_init(
        address market_,
        address accountOwner_,
        address tradeExecutor_,
        address business_,
        uint256 capacityMultiplier_,
        uint256 ownerShareBps_,
        uint256 businessShareBps_
    ) internal onlyInitializing {
        require(market_ != address(0) && accountOwner_ != address(0) && tradeExecutor_ != address(0), "Invalid address");
        require(capacityMultiplier_ >= 1000, "Invalid capacity multiplier");
        require(ownerShareBps_ <= BPS && businessShareBps_ == BPS - ownerShareBps_, "Invalid release shares");
        if (businessShareBps_ > 0) {
            require(business_ != address(0), "Invalid business");
        }
        if (ownerShareBps_ > 0 && businessShareBps_ > 0) {
            require(business_ != accountOwner_, "Owner and business must differ");
        }

        address settlement_ = IMarket(market_).settlementAsset();
        require(settlement_ != address(0), "Invalid settlement asset");
        address token_ = ISettlementAsset(settlement_).asset();
        require(token_ != address(0), "Invalid underlying");

        __Ownable_init(accountOwner_);

        market = IMarket(market_);
        settlementAsset = settlement_;
        underlying = IERC20(token_);
        tradeExecutor = tradeExecutor_;
        business = business_;
        accountOwner = accountOwner_;
        capacityMultiplier = capacityMultiplier_;
        ownerShareBps = ownerShareBps_;
        businessShareBps = businessShareBps_;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setTradeExecutor(address newTradeExecutor) external onlyOwner {
        require(newTradeExecutor != address(0), "Invalid address");
        address old = tradeExecutor;
        tradeExecutor = newTradeExecutor;
        emit TradeExecutorUpdated(old, newTradeExecutor);
    }

    function setBusiness(address newBusiness) external onlyOwner {
        if (businessShareBps > 0) {
            require(newBusiness != address(0), "Invalid business");
        }
        if (ownerShareBps > 0 && businessShareBps > 0) {
            require(newBusiness != accountOwner, "Owner and business must differ");
        }
        address old = business;
        business = newBusiness;
        emit BusinessUpdated(old, newBusiness);
    }

    function releaseAvailable() public view returns (uint256 ownerAmount, uint256 businessAmount) {
        ownerAmount = Math.mulDiv(received, ownerShareBps, BPS) - ownerReleased;
        businessAmount = Math.mulDiv(received, businessShareBps, BPS) - businessReleased;
    }

    function tradeIn(
        address registeredRightsOwner,
        uint160 rechargeTarget,
        uint256 netAmount,
        uint256 deltaW,
        bytes calldata data
    ) external override nonReentrant {
        require(msg.sender == tradeExecutor, "Only trade executor");
        require(registeredRightsOwner == accountOwner, "Wrong account owner");
        uint256 activeId = _activeAccount();

        received += netAmount;
        emit SaleRecorded(activeId, rechargeTarget, netAmount, deltaW);
        _tradeIn(rechargeTarget, netAmount, deltaW, data);
    }

    /// @notice The Account Owner or business spends its own fixed share through this one Market account.
    /// @dev sellerAccountId must identify an active seller; Market enforces that and the tier flow.
    function tradeOut(uint256 sellerAccountId, uint160 rechargeTarget, uint256 amount, bytes calldata data)
        external
        nonReentrant
    {
        require(amount > 0, "Invalid amount");
        uint256 activeId = _activeAccount();
        (uint256 ownerAvailable, uint256 businessAvailable) = releaseAvailable();

        if (msg.sender == accountOwner && ownerShareBps > 0) {
            require(amount <= ownerAvailable, "Owner release exceeds received");
            ownerReleased += amount;
            emit OwnerReleaseRecorded(activeId, amount);
        } else if (msg.sender == business && businessShareBps > 0) {
            require(amount <= businessAvailable, "Business release exceeds received");
            businessReleased += amount;
            emit BusinessReleaseRecorded(activeId, amount);
        } else {
            revert("Only account owner or business");
        }

        underlying.forceApprove(settlementAsset, amount);
        market.trade(accountOwner, activeId, sellerAccountId, rechargeTarget, amount, data);
        underlying.forceApprove(settlementAsset, 0);
    }

    /// @notice Use the fixed Account Owner share to increase this account's Market deposit.
    /// @dev Consumes the owner allowance; Market credits the deposit to the fixed account.
    function addDepositFromOwnerShare(uint256 amount) external nonReentrant {
        require(msg.sender == accountOwner, "Only account owner");
        require(amount > 0, "Invalid amount");
        uint256 activeId = _activeAccount();
        (uint256 ownerAvailable,) = releaseAvailable();
        require(amount <= ownerAvailable, "Owner release exceeds received");

        ownerReleased += amount;
        underlying.forceApprove(settlementAsset, amount);
        market.addDeposit(activeId, amount);
        underlying.forceApprove(settlementAsset, 0);
        emit OwnerShareDeposited(activeId, amount);
    }

    function _tradeIn(uint160 rechargeTarget, uint256 netAmount, uint256 deltaW, bytes calldata data) internal virtual;

    function _activeAccount() private returns (uint256 activeId) {
        activeId = market.accountIdOf(accountOwner, address(this));
        require(activeId != 0, "Market account not found");
        require(accountId == 0 || accountId == activeId, "Market account changed");

        (address registeredOwner, address registeredMerchant,, uint256 multiplier, bool active) =
            market.accounts(activeId);
        require(active, "Market account not active");
        require(registeredOwner == accountOwner && registeredMerchant == address(this), "Invalid market account");
        require(multiplier == capacityMultiplier, "Capacity tier changed");
        require(!market.isAccountFrozen(activeId), "Market account frozen");

        if (accountId == 0) accountId = activeId;
    }
}
