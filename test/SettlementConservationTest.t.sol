// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Market.sol";
import "../src/TradeExecutor.sol";
import "../src/settlement/ERC20SettlementAsset.sol";
import "../src/interfaces/IMerchantTradeIn.sol";

contract ConservationToken is ERC20 {
    constructor() ERC20("Conservation token", "CT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ConservationReceiver is IMerchantTradeIn {
    IERC20 public immutable token;
    address public immutable executor;
    uint256 public balanceAtCallback;
    uint256 public received;
    bool public reject;

    constructor(IERC20 token_, address executor_) {
        token = token_;
        executor = executor_;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function tradeIn(address, uint160, uint256 netAmount, bytes calldata) external {
        require(msg.sender == executor, "Only executor");
        require(!reject, "Receiver rejected");
        balanceAtCallback = token.balanceOf(address(this));
        received += netAmount;
    }
}

contract SettlementConservationTest is Test {
    ConservationToken private token;
    ConservationToken private buyerRights;
    ConservationToken private sellerRights;
    Market private market;
    ERC20SettlementAsset private settlement;
    ConservationReceiver private receiver;
    address private constant BUYER = address(0xB0);
    address private constant SELLER = address(0xA0);
    address private constant VAULT = address(0xF0);
    uint256 private constant DEPOSIT = 1000e6;
    uint256 private sellerId;

    function setUp() public {
        token = new ConservationToken();
        buyerRights = new ConservationToken();
        sellerRights = new ConservationToken();
        settlement = ERC20SettlementAsset(
            address(
                new ERC1967Proxy(
                    address(new ERC20SettlementAsset()),
                    abi.encodeCall(ERC20SettlementAsset.initialize, (address(token), address(this)))
                )
            )
        );
        market = Market(
            address(
                new ERC1967Proxy(
                    address(new Market()),
                    abi.encodeCall(
                        Market.initialize,
                        (address(settlement), address(buyerRights), address(sellerRights), address(this), VAULT)
                    )
                )
            )
        );
        TradeExecutor executor = new TradeExecutor(address(market), address(settlement));
        market.setExecutor(address(executor));
        settlement.setController(address(market), true);
        settlement.setController(address(executor), true);
        receiver = new ConservationReceiver(token, address(executor));
        token.mint(SELLER, DEPOSIT);
        token.mint(BUYER, 10000e6);
        vm.startPrank(SELLER);
        token.approve(address(settlement), DEPOSIT);
        sellerId = market.registerMerchant(address(receiver), DEPOSIT, 40000);
        vm.stopPrank();
        vm.prank(BUYER);
        token.approve(address(settlement), type(uint256).max);
    }

    function testFuzzTradeConservesCashAndTransfersBeforeCallback(uint256 amount) public {
        amount = bound(amount, 1, 4000e6);
        uint256 fee = amount / 100;
        uint256 netAmount = amount - fee;
        uint256 beforeBuyer = token.balanceOf(BUYER);

        vm.prank(BUYER);
        market.trade(BUYER, 0, sellerId, 7, amount, "");

        assertEq(beforeBuyer - token.balanceOf(BUYER), amount);
        assertEq(token.balanceOf(VAULT), fee);
        assertEq(token.balanceOf(address(receiver)), netAmount);
        assertEq(receiver.balanceAtCallback(), netAmount);
        assertEq(receiver.received(), netAmount);
        assertEq(token.balanceOf(address(settlement)), DEPOSIT);
        assertEq(token.balanceOf(address(market)), 0);
        assertEq(token.balanceOf(market.executor()), 0);
        assertEq(buyerRights.balanceOf(BUYER), fee);
        assertEq(sellerRights.balanceOf(SELLER), fee);
        assertEq(market.netTradeBalance(sellerId), int256(netAmount));
        assertEq(market.netTradeBalance(market.accountIdOf(BUYER, BUYER)), -int256(netAmount));
    }

    function testExactCapacityPaysFullNetAndNextSaleRevertsAtomically() public {
        uint256 capacity = market.capacityOf(sellerId);
        uint256 amount = capacity + (capacity - 1) / 99;
        vm.prank(BUYER);
        market.trade(BUYER, 0, sellerId, 7, amount, "");
        assertEq(token.balanceOf(address(receiver)), capacity);
        assertEq(market.effectiveSurplus(sellerId), capacity);

        uint256 beforeBuyer = token.balanceOf(BUYER);
        uint256 beforeVault = token.balanceOf(VAULT);
        vm.prank(BUYER);
        vm.expectRevert("Capacity exceeded");
        market.trade(BUYER, 0, sellerId, 7, 1, "");
        assertEq(token.balanceOf(BUYER), beforeBuyer);
        assertEq(token.balanceOf(VAULT), beforeVault);
        assertEq(receiver.received(), capacity);
        assertEq(market.effectiveSurplus(sellerId), capacity);
        assertEq(token.balanceOf(address(settlement)), DEPOSIT);
    }

    function testCallbackFailureRestoresCashRightsAndLazyAccount() public {
        receiver.setReject(true);
        uint256 beforeBuyer = token.balanceOf(BUYER);
        uint256 beforeNextId = market.nextAccountId();
        vm.prank(BUYER);
        vm.expectRevert("Receiver rejected");
        market.trade(BUYER, 0, sellerId, 7, 100e6, "");

        assertEq(token.balanceOf(BUYER), beforeBuyer);
        assertEq(token.balanceOf(address(settlement)), DEPOSIT);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(token.balanceOf(VAULT), 0);
        assertEq(buyerRights.totalSupply(), 0);
        assertEq(sellerRights.totalSupply(), 0);
        assertEq(market.accountIdOf(BUYER, BUYER), 0);
        assertEq(market.nextAccountId(), beforeNextId);
        assertEq(market.netTradeBalance(sellerId), 0);
        assertEq(receiver.received(), 0);
    }
}
