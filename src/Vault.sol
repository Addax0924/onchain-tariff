// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IMarket.sol";
import "./interfaces/ISettlementAsset.sol";
import "./interfaces/IMerchantTradeIn.sol";

interface IVaultMarket is IMarket {
    function governance() external view returns (address);
}

/**
 * @notice Holds the Market rights fee and spends it only through approved Market trades.
 * @dev Market governance is the timelock, not the governor implementation.
 */
contract Vault is IMerchantTradeIn, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct TradeInput {
        uint256 sellerAccountId;
        uint160 rechargeTarget;
        uint256 amount;
        bytes data;
    }

    struct TradeOrder {
        uint256 sellerAccountId;
        uint160 rechargeTarget;
        uint256 amount;
        bytes data;
        bool executed;
        bool canceled;
    }

    IVaultMarket public immutable market;
    ISettlementAsset public immutable settlementAsset;
    IERC20 public immutable underlying;
    address public immutable governance;

    // A smaller multiplier is stricter. Zero disables spending until governance sets a limit.
    uint256 public capacityMultiplierLimit;
    TradeOrder[] public tradeOrders;

    event CapacityMultiplierLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event TradeQueued(uint256 indexed orderId, uint256 indexed sellerAccountId, uint256 amount);
    event TradeExecuted(uint256 indexed orderId, uint256 indexed sellerAccountId, uint256 amount);
    event TradeCanceled(uint256 indexed orderId);

    modifier onlyGovernance() {
        require(msg.sender == governance, "Only governance");
        _;
    }

    constructor(address market_) {
        require(market_ != address(0), "Invalid market");
        IVaultMarket configuredMarket = IVaultMarket(market_);
        address governance_ = configuredMarket.governance();
        address settlement_ = configuredMarket.settlementAsset();
        require(governance_ != address(0) && settlement_ != address(0), "Invalid market configuration");
        address token_ = ISettlementAsset(settlement_).asset();
        require(token_ != address(0), "Invalid underlying");

        market = configuredMarket;
        settlementAsset = ISettlementAsset(settlement_);
        underlying = IERC20(token_);
        governance = governance_;
    }

    function tradeOrderCount() external view returns (uint256) {
        return tradeOrders.length;
    }

    /** @notice Set or tighten the Vault's independent spending limit. */
    function setCapacityMultiplierLimit(uint256 newMultiplier) external onlyGovernance {
        require(newMultiplier >= 1000, "Invalid capacity multiplier");
        uint256 oldLimit = capacityMultiplierLimit;
        require(oldLimit == 0 || newMultiplier <= oldLimit, "Cannot loosen limit");

        uint256 currentId = market.accountIdOf(address(this), address(this));
        require(currentId != 0, "Vault buyer account missing");
        (address owner, address merchant,, uint256 marketTier, bool active) = market.accounts(currentId);
        require(owner == address(this) && merchant == address(this) && !active, "Vault account invalid");
        require(newMultiplier <= marketTier, "Vault limit exceeds Market tier");
        capacityMultiplierLimit = newMultiplier;
        emit CapacityMultiplierLimitUpdated(oldLimit, newMultiplier);
    }

    /** @notice Governance may submit a list in multiple transactions if it is too large for one block. */
    function queueTrades(TradeInput[] calldata inputs) external onlyGovernance {
        for (uint256 i = 0; i < inputs.length; ++i) {
            TradeInput calldata input = inputs[i];
            require(input.sellerAccountId != 0, "Invalid seller account");
            require(input.amount > 0, "Invalid amount");
            uint256 orderId = tradeOrders.length;
            tradeOrders.push(
                TradeOrder({
                    sellerAccountId: input.sellerAccountId,
                    rechargeTarget: input.rechargeTarget,
                    amount: input.amount,
                    data: input.data,
                    executed: false,
                    canceled: false
                })
            );
            emit TradeQueued(orderId, input.sellerAccountId, input.amount);
        }
    }

    function cancelTrade(uint256 orderId) external onlyGovernance {
        require(orderId < tradeOrders.length, "Unknown order");
        TradeOrder storage order = tradeOrders[orderId];
        require(!order.executed && !order.canceled, "Order closed");
        order.canceled = true;
        emit TradeCanceled(orderId);
    }

    /** @notice Anyone may execute an approved order; neither the destination nor terms are caller-controlled. */
    function executeTrade(uint256 orderId) external nonReentrant {
        require(orderId < tradeOrders.length, "Unknown order");
        TradeOrder storage order = tradeOrders[orderId];
        require(!order.executed && !order.canceled, "Order closed");

        require(capacityMultiplierLimit != 0, "Vault limit not set");

        (,,, uint256 sellerMultiplier, bool sellerActive) = market.accounts(order.sellerAccountId);
        require(sellerActive, "Seller not active");
        require(sellerMultiplier <= capacityMultiplierLimit, "Seller limit exceeds Vault limit");

        order.executed = true;
        underlying.forceApprove(address(settlementAsset), order.amount);
        market.trade(address(this), 0, order.sellerAccountId, order.rechargeTarget, order.amount, order.data);
        underlying.forceApprove(address(settlementAsset), 0);
        emit TradeExecuted(orderId, order.sellerAccountId, order.amount);
    }

    /** @dev A Vault sale would create surplus, so it can never act as a seller. */
    function tradeIn(address, uint160, uint256, uint256, bytes calldata) external pure override {
        revert("Vault cannot sell");
    }
}
