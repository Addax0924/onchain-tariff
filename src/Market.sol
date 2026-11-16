// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import "./interfaces/ITradeExecutor.sol";
import "./interfaces/IRightsToken.sol";
import "./interfaces/ISettlementAsset.sol";

contract Market is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardTransient {
    uint256 public constant BPS = 10000;
    uint256 public constant WAD = 1e18;
    uint256 public constant MIN_CAPACITY_MULTIPLIER = 1000;
    uint256 public constant RESOLUTION_PERIOD = 30 days;
    uint256 public constant DEPOSIT_WITHDRAWAL_DELAY = 180 days;

    ISettlementAsset public settlementAsset;
    IRightsToken public buyerRights;
    IRightsToken public sellerRights;
    address public vault;
    address public governance;
    address public executor;

    struct MarketAccount {
        address owner;
        address merchant;
        uint256 deposit;
        uint256 capacityMultiplier;
        bool isActive;
    }

    struct TradeCalculation {
        uint256 vaultFee;
        uint256 tradeValue;
        uint256 resolvedSurplus;
        int256 newSellerBalance;
        int256 newBuyerBalance;
    }

    struct DepositWithdrawal {
        uint256 amount;
        uint256 availableAt;
    }

    uint256 public nextAccountId;
    mapping(uint256 => MarketAccount) public accounts;
    mapping(address => mapping(address => uint256)) public accountIdOf;

    mapping(uint256 => int256) public netTradeBalance;
    mapping(uint256 => uint256) private _deferredSurplus;
    mapping(uint256 => uint256) private _deferredReleaseIndex;
    mapping(uint256 => uint256) private _deferredReleaseRemainder;

    uint256 public resolutionRatio;
    uint256 public resolutionIndex;
    uint256 public resolutionIndexUpdatedAt;
    // Pending funds no longer provide capacity or release deferred surplus.
    mapping(uint256 => DepositWithdrawal) public depositWithdrawals;
    mapping(uint256 => bool) public isAccountFrozen;

    modifier notFromExecutor() {
        require(msg.sender != executor, "Executor cannot trigger trade");
        _;
    }

    event AccountCreated(uint256 indexed accountId, address indexed owner, address indexed merchant);
    event MerchantRegistered(
        uint256 indexed accountId,
        address indexed owner,
        address indexed merchant,
        uint256 deposit,
        uint256 capacityMultiplier
    );
    event MerchantDepositIncreased(
        uint256 indexed accountId, address indexed payer, uint256 amount, uint256 totalDeposit
    );
    event CapacityMultiplierUpdated(uint256 indexed accountId, uint256 oldMultiplier, uint256 newMultiplier);
    event DepositWithdrawalRequested(
        uint256 indexed accountId, address indexed owner, uint256 amount, uint256 availableAt
    );
    event DepositWithdrawn(uint256 indexed accountId, address indexed recipient, uint256 amount);
    event Traded(
        address indexed payer,
        address indexed buyer,
        uint256 indexed sellerAccountId,
        uint256 buyerAccountId,
        address merchant,
        uint256 amount,
        uint256 netAmount
    );
    event TradeBalanceChanged(
        uint256 indexed buyerAccountId,
        uint256 indexed sellerAccountId,
        address indexed buyer,
        address merchant,
        int256 oldBuyerBalance,
        int256 newBuyerBalance,
        int256 oldMerchantBalance,
        int256 newMerchantBalance
    );
    event TradeBalanceUpdated(uint256 indexed accountId, int256 netTradeBalance);
    event MerchantKicked(
        uint256 indexed accountId,
        address indexed owner,
        address indexed merchant,
        uint256 slashedAmount,
        uint256 ownerRefund
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _settlementAsset,
        address _buyerRights,
        address _sellerRights,
        address _governance,
        address _vault
    ) public initializer {
        __Ownable_init(msg.sender);
        settlementAsset = ISettlementAsset(_settlementAsset);
        buyerRights = IRightsToken(_buyerRights);
        sellerRights = IRightsToken(_sellerRights);
        governance = _governance;
        vault = _vault;
        nextAccountId = 1;
        resolutionRatio = 5000;
        resolutionIndexUpdatedAt = block.timestamp;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function underlying() external view returns (IERC20) {
        return IERC20(settlementAsset.asset());
    }

    function _positive(int256 value) internal pure returns (uint256) {
        return value > 0 ? uint256(value) : 0;
    }

    function _negativeMagnitude(int256 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : 0;
    }

    function _toInt256(uint256 value) internal pure returns (int256) {
        require(value <= uint256(type(int256).max), "Value too large");
        return int256(value);
    }

    function _createAccount(address owner, address merchant) internal returns (uint256 accountId) {
        require(owner != address(0), "Invalid owner");
        require(merchant != address(0), "Invalid merchant");
        require(accountIdOf[owner][merchant] == 0, "Account already exists");

        accountId = nextAccountId++;
        accounts[accountId].owner = owner;
        accounts[accountId].merchant = merchant;
        accountIdOf[owner][merchant] = accountId;
        emit AccountCreated(accountId, owner, merchant);
    }

    function _resolveBuyerAccount(address buyer, uint256 buyerAccountId) internal returns (uint256 resolvedAccountId) {
        require(buyer != address(0), "Invalid buyer");

        if (buyerAccountId == 0) {
            resolvedAccountId = accountIdOf[buyer][buyer];
            if (resolvedAccountId == 0) {
                resolvedAccountId = _createAccount(buyer, buyer);
            }
            return resolvedAccountId;
        }

        MarketAccount storage account = accounts[buyerAccountId];
        require(account.owner != address(0), "Buyer account not found");
        require(account.owner == buyer, "Buyer is not account owner");
        return buyerAccountId;
    }

    function deferredSurplus(uint256 accountId) public view returns (uint256) {
        (uint256 current,,) = _previewDeferredSurplus(accountId);
        return current;
    }

    /// @notice Effective Surplus: positive real balance plus current deferred surplus.
    function effectiveSurplus(uint256 accountId) public view returns (uint256) {
        return _positive(netTradeBalance[accountId]) + deferredSurplus(accountId);
    }

    /// @notice Deposit-backed capacity: deposit * capacityMultiplier / BPS.
    function capacityOf(uint256 accountId) public view returns (uint256) {
        MarketAccount storage account = accounts[accountId];
        return _capacity(account.deposit, account.capacityMultiplier);
    }

    function _capacity(uint256 deposit, uint256 capacityMultiplier) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(deposit, capacityMultiplier, BPS);
    }

    function _currentResolutionIndex() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - resolutionIndexUpdatedAt;
        if (elapsed == 0 || resolutionRatio == 0) return resolutionIndex;

        uint256 scaledRatio = FixedPointMathLib.fullMulDiv(resolutionRatio, WAD, BPS);
        uint256 indexGrowth = FixedPointMathLib.fullMulDiv(scaledRatio, elapsed, RESOLUTION_PERIOD);
        return resolutionIndex + indexGrowth;
    }

    function _previewDeferredSurplus(uint256 accountId)
        internal
        view
        returns (uint256 current, uint256 currentIndex, uint256 remainder)
    {
        current = _deferredSurplus[accountId];
        currentIndex = _currentResolutionIndex();
        if (current == 0) return (0, currentIndex, 0);

        uint256 accountIndex = _deferredReleaseIndex[accountId];
        if (currentIndex <= accountIndex) {
            return (current, currentIndex, _deferredReleaseRemainder[accountId]);
        }

        uint256 deltaIndex = currentIndex - accountIndex;
        uint256 deposit = accounts[accountId].deposit;
        uint256 released = FixedPointMathLib.fullMulDiv(deposit, deltaIndex, WAD);
        remainder = mulmod(deposit, deltaIndex, WAD) + _deferredReleaseRemainder[accountId];
        if (remainder >= WAD) {
            released += 1;
            remainder -= WAD;
        }

        if (released >= current) return (0, currentIndex, 0);
        current -= released;
    }

    function _syncDeferredSurplus(uint256 accountId) internal returns (uint256 current) {
        uint256 currentIndex;
        uint256 remainder;
        (current, currentIndex, remainder) = _previewDeferredSurplus(accountId);
        _deferredSurplus[accountId] = current;
        _deferredReleaseIndex[accountId] = currentIndex;
        _deferredReleaseRemainder[accountId] = remainder;
    }

    function _addDeferredSurplus(uint256 accountId, uint256 amount) internal {
        if (amount == 0) return;
        uint256 current = _syncDeferredSurplus(accountId);
        _deferredSurplus[accountId] = current + amount;
    }

    function _syncResolutionIndex() internal {
        resolutionIndex = _currentResolutionIndex();
        resolutionIndexUpdatedAt = block.timestamp;
    }

    function _calculateSellerTrade(uint256 sellerAccountId, TradeCalculation memory calculation) internal view {
        MarketAccount storage account = accounts[sellerAccountId];
        require(account.isActive, "Merchant account not active");
        require(!isAccountFrozen[sellerAccountId], "Account frozen");
        require(calculation.tradeValue > 0, "Invalid trade value");

        int256 tradeValueInt = _toInt256(calculation.tradeValue);
        int256 oldSellerBalance = netTradeBalance[sellerAccountId];
        calculation.newSellerBalance = oldSellerBalance + tradeValueInt;

        uint256 surplus = _positive(calculation.newSellerBalance) + deferredSurplus(sellerAccountId);
        if (surplus > 0) {
            require(surplus <= _capacity(account.deposit, account.capacityMultiplier), "Capacity exceeded");
        }
    }

    function _calculateBuyerTrade(uint256 buyerAccountId, TradeCalculation memory calculation) internal view {
        int256 tradeValueInt = _toInt256(calculation.tradeValue);
        int256 oldBuyerBalance = netTradeBalance[buyerAccountId];
        calculation.newBuyerBalance = oldBuyerBalance - tradeValueInt;

        // Surplus that disappears together with the seller's deficit stays effective for a while,
        // so bots cannot net many accounts' surpluses and deficits away at once.
        int256 oldSellerBalance = calculation.newSellerBalance - tradeValueInt;
        uint256 buyerSurplusReduced = _positive(oldBuyerBalance) - _positive(calculation.newBuyerBalance);
        uint256 sellerDeficitReduced =
            _negativeMagnitude(oldSellerBalance) - _negativeMagnitude(calculation.newSellerBalance);
        calculation.resolvedSurplus =
            buyerSurplusReduced < sellerDeficitReduced ? buyerSurplusReduced : sellerDeficitReduced;
    }

    function registerMerchant(address merchant, uint256 amount, uint256 capacityMultiplier)
        external
        nonReentrant
        returns (uint256 accountId)
    {
        require(amount > 0, "Deposit required");
        require(merchant != address(0), "Invalid merchant");
        require(capacityMultiplier >= MIN_CAPACITY_MULTIPLIER, "Invalid capacity multiplier");

        accountId = accountIdOf[msg.sender][merchant];
        if (accountId == 0) {
            accountId = _createAccount(msg.sender, merchant);
        }

        MarketAccount storage account = accounts[accountId];
        require(!account.isActive, "Merchant account already active");
        uint256 previousMultiplier = account.capacityMultiplier;
        if (previousMultiplier != 0) {
            require(capacityMultiplier <= previousMultiplier, "Multiplier can only decrease");
            if (netTradeBalance[accountId] < 0) {
                require(capacityMultiplier == previousMultiplier, "Outstanding deficit");
            }
        } else {
            require(netTradeBalance[accountId] == 0, "Buyer tier missing");
        }

        settlementAsset.pull(msg.sender, amount);
        account.deposit = amount;
        account.capacityMultiplier = capacityMultiplier;
        account.isActive = true;

        emit MerchantRegistered(accountId, account.owner, account.merchant, amount, capacityMultiplier);
    }

    function addDeposit(uint256 accountId, uint256 amount) external nonReentrant {
        require(amount > 0, "Deposit required");
        MarketAccount storage account = accounts[accountId];
        require(account.isActive, "Merchant account not active");
        require(!isAccountFrozen[accountId], "Account frozen");

        _syncDeferredSurplus(accountId);
        settlementAsset.pull(msg.sender, amount);
        account.deposit += amount;

        emit MerchantDepositIncreased(accountId, msg.sender, amount, account.deposit);
    }

    function requestDepositWithdrawal(uint256 accountId) external nonReentrant {
        MarketAccount storage account = accounts[accountId];
        require(account.isActive, "Merchant account not active");
        require(msg.sender == account.owner, "Only account owner");
        require(depositWithdrawals[accountId].amount == 0, "Deposit withdrawal pending");
        require(account.deposit > 0, "Deposit required");
        require(netTradeBalance[accountId] <= 0, "Outstanding surplus");
        require(_syncDeferredSurplus(accountId) == 0, "Outstanding deferred surplus");

        uint256 amount = account.deposit;
        uint256 availableAt = block.timestamp + DEPOSIT_WITHDRAWAL_DELAY;
        account.deposit = 0;
        depositWithdrawals[accountId] = DepositWithdrawal(amount, availableAt);
        isAccountFrozen[accountId] = true;

        // Preserve the account while pending, but block both trade directions until deletion.
        emit DepositWithdrawalRequested(accountId, account.owner, amount, availableAt);
    }

    function withdrawDeposit(uint256 accountId) external nonReentrant {
        MarketAccount memory account = accounts[accountId];
        require(msg.sender == account.owner, "Only account owner");
        DepositWithdrawal memory withdrawal = depositWithdrawals[accountId];
        require(withdrawal.amount > 0, "No deposit withdrawal");
        require(block.timestamp >= withdrawal.availableAt, "Deposit withdrawal not ready");

        delete accountIdOf[account.owner][account.merchant];
        delete accounts[accountId];
        delete netTradeBalance[accountId];
        delete _deferredSurplus[accountId];
        delete _deferredReleaseIndex[accountId];
        delete _deferredReleaseRemainder[accountId];
        delete depositWithdrawals[accountId];
        delete isAccountFrozen[accountId];
        settlementAsset.push(account.owner, withdrawal.amount);
        emit TradeBalanceUpdated(accountId, 0);
        emit DepositWithdrawn(accountId, account.owner, withdrawal.amount);
    }

    function setCapacityMultiplier(uint256 accountId, uint256 newMultiplier) external {
        MarketAccount storage account = accounts[accountId];
        require(account.isActive, "Merchant account not active");
        require(msg.sender == account.owner, "Only account owner");
        require(!isAccountFrozen[accountId], "Account frozen");
        require(newMultiplier >= MIN_CAPACITY_MULTIPLIER, "Invalid capacity multiplier");
        uint256 oldMultiplier = account.capacityMultiplier;
        require(newMultiplier <= oldMultiplier, "Multiplier can only decrease");
        if (newMultiplier < oldMultiplier) {
            require(netTradeBalance[accountId] >= 0, "Outstanding deficit");
        }

        uint256 surplus = effectiveSurplus(accountId);
        if (surplus > 0) {
            require(surplus <= _capacity(account.deposit, newMultiplier), "Capacity exceeded");
        }

        account.capacityMultiplier = newMultiplier;
        emit CapacityMultiplierUpdated(accountId, oldMultiplier, newMultiplier);
    }

    function trade(
        address buyer,
        uint256 buyerAccountId,
        uint256 sellerAccountId,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant notFromExecutor {
        require(amount > 0, "Invalid amount");

        buyerAccountId = _resolveBuyerAccount(buyer, buyerAccountId);
        require(buyerAccountId != sellerAccountId, "Self trade not allowed");
        require(!isAccountFrozen[buyerAccountId], "Account frozen");

        MarketAccount storage buyerAccount = accounts[buyerAccountId];
        MarketAccount storage sellerAccount = accounts[sellerAccountId];
        require(sellerAccount.isActive, "Merchant account not active");
        if (buyerAccount.isActive) {
            require(sellerAccount.capacityMultiplier <= buyerAccount.capacityMultiplier, "Seller multiplier too high");
        } else {
            // Inactive buyers keep their first seller tier when buying from stricter sellers.
            uint256 buyerTier = buyerAccount.capacityMultiplier;
            if (netTradeBalance[buyerAccountId] == 0 || buyerTier == 0) {
                require(msg.sender == buyer, "First trade must be self-paid");
            }
            if (buyerTier == 0) {
                buyerAccount.capacityMultiplier = sellerAccount.capacityMultiplier;
            } else {
                require(sellerAccount.capacityMultiplier <= buyerTier, "Seller multiplier too high");
            }
        }

        TradeCalculation memory calculation;
        calculation.vaultFee = amount / 100;
        calculation.tradeValue = amount - calculation.vaultFee;
        _calculateSellerTrade(sellerAccountId, calculation);
        _calculateBuyerTrade(buyerAccountId, calculation);

        netTradeBalance[sellerAccountId] = calculation.newSellerBalance;
        netTradeBalance[buyerAccountId] = calculation.newBuyerBalance;
        _addDeferredSurplus(buyerAccountId, calculation.resolvedSurplus);

        settlementAsset.pull(msg.sender, amount);
        settlementAsset.push(vault, calculation.vaultFee);

        if (buyerAccount.owner != vault || buyerAccount.merchant != vault) {
            buyerRights.mint(buyerAccount.owner, calculation.vaultFee);
        }
        sellerRights.mint(sellerAccount.owner, calculation.vaultFee);

        ITradeExecutor(executor)
            .executeTrade(sellerAccount.merchant, sellerAccount.owner, rechargeTarget, calculation.tradeValue, data);

        emit TradeBalanceUpdated(sellerAccountId, calculation.newSellerBalance);
        emit TradeBalanceUpdated(buyerAccountId, calculation.newBuyerBalance);
        int256 tradeValue = _toInt256(calculation.tradeValue);
        emit TradeBalanceChanged(
            buyerAccountId,
            sellerAccountId,
            buyer,
            sellerAccount.merchant,
            calculation.newBuyerBalance + tradeValue,
            calculation.newBuyerBalance,
            calculation.newSellerBalance - tradeValue,
            calculation.newSellerBalance
        );
        emit Traded(
            msg.sender, buyer, sellerAccountId, buyerAccountId, sellerAccount.merchant, amount, calculation.tradeValue
        );
    }

    function kickMerchant(uint256 accountId) external nonReentrant {
        require(msg.sender == governance, "Only governance");
        MarketAccount memory account = accounts[accountId];
        require(account.isActive, "Merchant account not active");

        // Effective deposit includes a pending withdrawal; slash at most the Effective Surplus.
        uint256 depositAmount = account.deposit + depositWithdrawals[accountId].amount;
        uint256 surplus = effectiveSurplus(accountId);
        uint256 slashedAmount = surplus < depositAmount ? surplus : depositAmount;
        uint256 ownerRefund = depositAmount - slashedAmount;

        delete depositWithdrawals[accountId];
        delete isAccountFrozen[accountId];
        delete accountIdOf[account.owner][account.merchant];
        delete accounts[accountId];
        delete netTradeBalance[accountId];
        delete _deferredSurplus[accountId];
        delete _deferredReleaseIndex[accountId];
        delete _deferredReleaseRemainder[accountId];

        settlementAsset.push(vault, slashedAmount);
        settlementAsset.push(account.owner, ownerRefund);
        emit TradeBalanceUpdated(accountId, 0);
        emit MerchantKicked(accountId, account.owner, account.merchant, slashedAmount, ownerRefund);
    }

    /// @notice Pin an inactive Vault buyer account to its maximum permitted Market tier.
    /// @dev A Vault may tighten its own spending limit without changing this historical tier.
    function setVault(address _newVault, uint256 initialTier) external onlyOwner {
        require(_newVault != address(0), "Invalid vault");
        require(initialTier >= MIN_CAPACITY_MULTIPLIER, "Invalid capacity multiplier");
        uint256 vaultAccountId = accountIdOf[_newVault][_newVault];
        if (vaultAccountId == 0) {
            vaultAccountId = _createAccount(_newVault, _newVault);
        }
        MarketAccount storage account = accounts[vaultAccountId];
        require(!account.isActive, "Vault account active");
        if (account.capacityMultiplier == 0) {
            require(netTradeBalance[vaultAccountId] == 0, "Vault account has history");
            account.capacityMultiplier = initialTier;
        } else {
            require(account.capacityMultiplier == initialTier, "Vault tier immutable");
        }
        vault = _newVault;
    }

    function setExecutor(address _executor) external onlyOwner {
        executor = _executor;
    }

    function setResolutionParams(uint256 _newRatio) external onlyOwner {
        require(_newRatio <= BPS, "Invalid resolution ratio");
        _syncResolutionIndex();
        resolutionRatio = _newRatio;
    }
}
