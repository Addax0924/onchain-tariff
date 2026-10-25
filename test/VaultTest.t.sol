// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Market.sol";
import "../src/Vault.sol";
import "../src/TradeExecutor.sol";
import "../src/settlement/ERC20SettlementAsset.sol";

contract VaultTestToken is ERC20 {
    constructor() ERC20("Test token", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VaultTest is Test {
    Market internal market;
    Vault internal vault;
    VaultTestToken internal token;
    VaultTestToken internal buyerRights;
    VaultTestToken internal sellerRights;
    ERC20SettlementAsset internal settlement;
    address internal seller = address(0x51);
    address internal customer = address(0xC0);
    address internal keeper = address(0xA1);
    uint256 internal sellerId;

    function setUp() public {
        token = new VaultTestToken();
        buyerRights = new VaultTestToken();
        sellerRights = new VaultTestToken();
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
                        (address(settlement), address(buyerRights), address(sellerRights), address(this), address(0))
                    )
                )
            )
        );
        vault = new Vault(address(market));
        market.setVault(address(vault), 40000);
        TradeExecutor executor = new TradeExecutor(address(market), address(settlement));
        market.setExecutor(address(executor));
        settlement.setController(address(market), true);
        settlement.setController(address(executor), true);

        token.mint(seller, 1000e6);
        vm.startPrank(seller);
        token.approve(address(settlement), 1000e6);
        sellerId = market.registerMerchant(seller, 1000e6, 20000);
        vm.stopPrank();
    }

    function _fundVaultFromFee() internal {
        token.mint(customer, 100e6);
        vm.startPrank(customer);
        token.approve(address(settlement), 100e6);
        market.trade(customer, 0, sellerId, 0, 100e6, "");
        vm.stopPrank();
        assertEq(token.balanceOf(address(vault)), 1e6);
        assertEq(buyerRights.balanceOf(customer), 1e6);
        assertEq(sellerRights.balanceOf(seller), 1e6);
    }

    function _queue(uint256 sellerAccountId, uint256 amount) internal returns (uint256 orderId) {
        orderId = vault.tradeOrderCount();
        Vault.TradeInput[] memory inputs = new Vault.TradeInput[](1);
        inputs[0] = Vault.TradeInput(sellerAccountId, 42, amount, hex"1234");
        vault.queueTrades(inputs);
    }

    function testGovernanceSetsLocalLimitWithoutRegisteringOrDepositing() public {
        _fundVaultFromFee();
        vm.prank(keeper);
        vm.expectRevert("Only governance");
        vault.setCapacityMultiplierLimit(40000);

        vault.setCapacityMultiplierLimit(40000);
        uint256 id = market.accountIdOf(address(vault), address(vault));
        (address owner, address merchant, uint256 deposit, uint256 multiplier, bool active) = market.accounts(id);
        assertEq(owner, address(vault));
        assertEq(merchant, address(vault));
        assertEq(deposit, 0);
        assertEq(multiplier, 40000);
        assertFalse(active);
        assertEq(vault.capacityMultiplierLimit(), 40000);
        assertEq(market.netTradeBalance(id), 0);
        assertEq(token.balanceOf(address(vault)), 1e6);

        vault.setCapacityMultiplierLimit(30000);
        (,,, multiplier,) = market.accounts(id);
        assertEq(multiplier, 40000);
        assertEq(vault.capacityMultiplierLimit(), 30000);
        vm.expectRevert("Cannot loosen limit");
        vault.setCapacityMultiplierLimit(40000);
    }

    function testMarketVaultTierCannotBeLoweredAlongsideLocalLimit() public {
        uint256 vaultId = market.accountIdOf(address(vault), address(vault));
        vault.setCapacityMultiplierLimit(20000);
        (,,, uint256 marketTier, bool active) = market.accounts(vaultId);
        assertEq(marketTier, 40000);
        assertFalse(active);
        vm.expectRevert("Vault tier immutable");
        market.setVault(address(vault), 20000);
    }

    function testCannotExecuteBeforeGovernanceSetsLocalLimit() public {
        _fundVaultFromFee();
        uint256 orderId = _queue(sellerId, 100_000);
        vm.expectRevert("Vault limit not set");
        vault.executeTrade(orderId);
    }

    function testExecutesApprovedTradesOneAtATimeUsingFeeFunds() public {
        _fundVaultFromFee();
        vault.setCapacityMultiplierLimit(40000);
        uint256 vaultId = market.accountIdOf(address(vault), address(vault));
        uint256 order0 = _queue(sellerId, 400_000);
        uint256 order1 = _queue(sellerId, 300_000);
        uint256 sellerBalance = token.balanceOf(seller);

        vm.prank(keeper);
        vault.executeTrade(order0);
        assertEq(market.netTradeBalance(vaultId), -396_000);
        assertEq(token.balanceOf(address(vault)), 1e6 - 400_000 + 4_000);
        assertGt(token.balanceOf(seller), sellerBalance);
        assertEq(buyerRights.balanceOf(address(vault)), 0);
        assertEq(sellerRights.balanceOf(seller), 1e6 + 4_000);
        (,,,, bool executed0,) = vault.tradeOrders(order0);
        (,,,, bool executed1,) = vault.tradeOrders(order1);
        assertTrue(executed0);
        assertFalse(executed1);

        vm.prank(keeper);
        vault.executeTrade(order1);
        assertEq(market.netTradeBalance(vaultId), -693_000);
        assertEq(buyerRights.balanceOf(address(vault)), 0);
        assertEq(sellerRights.balanceOf(seller), 1e6 + 7_000);
        vm.expectRevert("Order closed");
        vault.executeTrade(order0);
    }

    function testDifferentOwnerWithVaultMerchantStillMintsBuyerRights() public {
        token.mint(customer, 100_001);
        vm.startPrank(customer);
        token.approve(address(settlement), 100_001);
        uint256 buyerId = market.registerMerchant(address(vault), 1, 40000);
        market.trade(customer, buyerId, sellerId, 0, 100_000, "");
        vm.stopPrank();

        (address owner, address merchant,,,) = market.accounts(buyerId);
        assertEq(owner, customer);
        assertEq(merchant, address(vault));
        assertEq(buyerRights.balanceOf(customer), 1_000);
        assertEq(sellerRights.balanceOf(seller), 1_000);
        assertEq(buyerRights.balanceOf(address(vault)), 0);
    }

    function testAllowsEqualSellerMultiplier() public {
        token.mint(address(vault), 1e6);
        vault.setCapacityMultiplierLimit(20000);
        uint256 orderId = _queue(sellerId, 100_000);
        vault.executeTrade(orderId);
        (,,,, bool executed,) = vault.tradeOrders(orderId);
        assertTrue(executed);
        assertEq(token.allowance(address(vault), address(settlement)), 0);
    }

    function testRejectsSellerMultiplierAboveOwnLimit() public {
        token.mint(address(vault), 1e6);
        vault.setCapacityMultiplierLimit(10000);
        uint256 orderId = _queue(sellerId, 100_000);
        vm.expectRevert("Seller limit exceeds Vault limit");
        vault.executeTrade(orderId);
        (,,,, bool executed,) = vault.tradeOrders(orderId);
        assertFalse(executed);
        assertEq(token.allowance(address(vault), address(settlement)), 0);
    }

    function testCancelAndGovernanceGate() public {
        _fundVaultFromFee();
        vault.setCapacityMultiplierLimit(40000);
        Vault.TradeInput[] memory inputs = new Vault.TradeInput[](1);
        inputs[0] = Vault.TradeInput(sellerId, 0, 100_000, "");
        vm.prank(keeper);
        vm.expectRevert("Only governance");
        vault.queueTrades(inputs);
        vault.queueTrades(inputs);
        vm.prank(keeper);
        vm.expectRevert("Only governance");
        vault.cancelTrade(0);
        vault.cancelTrade(0);
        vm.expectRevert("Order closed");
        vault.executeTrade(0);
    }

    function testVaultInactiveBuyerAccountCannotSell() public {
        _fundVaultFromFee();
        vault.setCapacityMultiplierLimit(40000);
        token.mint(customer, 2);
        vm.startPrank(customer);
        token.approve(address(settlement), 2);
        uint256 vaultId = market.accountIdOf(address(vault), address(vault));
        vm.expectRevert("Merchant account not active");
        market.trade(customer, 0, vaultId, 0, 2, "");
        vm.stopPrank();
        assertEq(market.netTradeBalance(vaultId), 0);
    }
}
