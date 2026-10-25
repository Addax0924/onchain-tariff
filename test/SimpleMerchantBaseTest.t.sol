// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/Market.sol";
import "../src/TradeExecutor.sol";
import "../src/settlement/ERC20SettlementAsset.sol";
import "../src/Merchant/SimpleMerchantBaseUpgradeable.sol";

contract SimpleMerchantTokenMock is ERC20 {
    constructor() ERC20("Settlement", "SET") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SimpleMerchantRightsMock {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract SimpleMerchantHarness is SimpleMerchantBase {
    uint160 public lastRechargeTarget;
    uint256 public lastNetAmount;
    uint256 public lastDeltaW;

    function initialize(
        address market_,
        address accountOwner_,
        address tradeExecutor_,
        address business_,
        uint256 capacityMultiplier_,
        uint256 ownerShareBps_,
        uint256 businessShareBps_
    ) external initializer {
        __SimpleMerchantBase_init(
            market_, accountOwner_, tradeExecutor_, business_, capacityMultiplier_, ownerShareBps_, businessShareBps_
        );
    }

    function _tradeIn(uint160 rechargeTarget, uint256 netAmount, uint256 deltaW, bytes calldata) internal override {
        lastRechargeTarget = rechargeTarget;
        lastNetAmount = netAmount;
        lastDeltaW = deltaW;
    }
}

contract SimpleMerchantBaseTest is Test {
    SimpleMerchantTokenMock internal token;
    SimpleMerchantRightsMock internal buyerRights;
    SimpleMerchantRightsMock internal sellerRights;
    ERC20SettlementAsset internal settlement;
    Market internal market;
    TradeExecutor internal executor;
    SimpleMerchantHarness internal merchant;

    address internal accountOwner = address(0xA11CE);
    address internal business = address(0xB051E55);
    address internal payer = address(0xCA11);
    address internal upstreamOwner = address(0xB0B);
    address internal anotherOwner = address(0xC0C0);

    uint256 internal merchantAccountId;
    uint256 internal upstreamAccountId;

    function setUp() public {
        token = new SimpleMerchantTokenMock();
        buyerRights = new SimpleMerchantRightsMock();
        sellerRights = new SimpleMerchantRightsMock();

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
                        (
                            address(settlement),
                            address(buyerRights),
                            address(sellerRights),
                            address(this),
                            address(0xFEE)
                        )
                    )
                )
            )
        );
        executor = new TradeExecutor(address(market), address(settlement));
        market.setExecutor(address(executor));
        settlement.setController(address(market), true);
        settlement.setController(address(executor), true);

        merchant = SimpleMerchantHarness(
            address(
                new ERC1967Proxy(
                    address(new SimpleMerchantHarness()),
                    abi.encodeCall(
                        SimpleMerchantHarness.initialize,
                        (address(market), accountOwner, address(executor), business, 40000, 4000, 6000)
                    )
                )
            )
        );

        token.mint(accountOwner, 5000e6);
        token.mint(upstreamOwner, 5000e6);
        token.mint(payer, 5000e6);
        token.mint(anotherOwner, 5000e6);

        merchantAccountId = _register(accountOwner, address(merchant), 40000);
        upstreamAccountId = _register(upstreamOwner, upstreamOwner, 30000);
    }

    function _register(address owner_, address merchant_, uint256 multiplier) internal returns (uint256 id) {
        vm.startPrank(owner_);
        token.approve(address(settlement), 1000e6);
        id = market.registerMerchant(merchant_, 1000e6, multiplier);
        vm.stopPrank();
    }

    function _sale(uint256 amount) internal {
        vm.startPrank(payer);
        token.approve(address(settlement), amount);
        market.trade(payer, 0, merchantAccountId, 7, amount, "");
        vm.stopPrank();
    }

    function testSaleBindsOneAccountAndRecordsOneReceipt() public {
        assertEq(merchant.owner(), accountOwner);
        assertEq(merchant.accountId(), 0);

        _sale(100e6);

        uint256 actualTariff = market.sellerPoints(merchantAccountId);
        assertEq(merchant.accountId(), merchantAccountId);
        assertEq(merchant.received(), 99e6);
        assertEq(merchant.lastRechargeTarget(), 7);
        assertEq(merchant.lastNetAmount(), 99e6);
        assertEq(merchant.lastDeltaW(), 99e6 - actualTariff);
        assertEq(token.balanceOf(address(merchant)), merchant.lastDeltaW());
        assertEq(sellerRights.balanceOf(accountOwner), 1e6);
        (uint256 ownerAvailable, uint256 businessAvailable) = merchant.releaseAvailable();
        assertEq(ownerAvailable, 39_600_000);
        assertEq(businessAvailable, 59_400_000);
    }

    function testOwnerAndBusinessSpendDistinctFixedSharesThroughBoundAccount() public {
        _sale(100e6);

        uint256 cashBefore = token.balanceOf(address(merchant));
        vm.prank(accountOwner);
        merchant.tradeOut(upstreamAccountId, 11, 10e6, "");
        uint256 cashSpent = cashBefore - token.balanceOf(address(merchant));
        assertLt(cashSpent, 10e6);
        assertGt(cashSpent, 100_000); // The rights fee is still paid.
        assertGt(market.claimed(merchantAccountId), 0);

        vm.prank(business);
        merchant.tradeOut(upstreamAccountId, 12, 10e6, "");

        assertEq(merchant.ownerReleased(), 10e6);
        assertEq(merchant.businessReleased(), 10e6);
        assertEq(market.netTradeBalance(merchantAccountId), int256(99e6 - 2 * 9_900_000));
        assertEq(token.allowance(address(merchant), address(settlement)), 0);

        (uint256 ownerAvailable, uint256 businessAvailable) = merchant.releaseAvailable();
        assertEq(ownerAvailable, 29_600_000);
        assertEq(businessAvailable, 49_400_000);
    }

    function testOwnerShareCanIncreaseDepositWithoutUsingBusinessShare() public {
        _sale(100e6);

        (,, uint256 depositBefore,,) = market.accounts(merchantAccountId);
        uint256 merchantCashBefore = token.balanceOf(address(merchant));
        uint256 ownerCashBefore = token.balanceOf(accountOwner);
        uint256 tariffBefore = market.sellerPoints(merchantAccountId);
        (, uint256 businessAvailableBefore) = merchant.releaseAvailable();

        vm.prank(accountOwner);
        merchant.addDepositFromOwnerShare(20e6);

        (,, uint256 depositAfter,,) = market.accounts(merchantAccountId);
        assertEq(depositAfter, depositBefore + 20e6);
        assertEq(merchantCashBefore - token.balanceOf(address(merchant)), 20e6);
        assertEq(token.balanceOf(accountOwner), ownerCashBefore);
        assertEq(market.sellerPoints(merchantAccountId), tariffBefore);
        assertEq(merchant.ownerReleased(), 20e6);
        assertEq(merchant.businessReleased(), 0);
        assertEq(token.allowance(address(merchant), address(settlement)), 0);

        (uint256 ownerAvailable, uint256 businessAvailable) = merchant.releaseAvailable();
        assertEq(ownerAvailable, 19_600_000);
        assertEq(businessAvailable, businessAvailableBefore);

        vm.prank(accountOwner);
        vm.expectRevert("Owner release exceeds received");
        merchant.tradeOut(upstreamAccountId, 0, 20e6, "");
    }

    function testOwnerShareDepositRequiresAccountOwnerAndAvailableShare() public {
        _sale(100e6);

        vm.prank(business);
        vm.expectRevert("Only account owner");
        merchant.addDepositFromOwnerShare(1e6);

        vm.prank(accountOwner);
        vm.expectRevert("Invalid amount");
        merchant.addDepositFromOwnerShare(0);

        vm.prank(accountOwner);
        vm.expectRevert("Owner release exceeds received");
        merchant.addDepositFromOwnerShare(40e6);

        assertEq(merchant.ownerReleased(), 0);
        (,, uint256 deposit,,) = market.accounts(merchantAccountId);
        assertEq(deposit, 1000e6);
    }

    function testReleaseAboveShareAndUnknownCallerRevert() public {
        _sale(100e6);

        vm.prank(accountOwner);
        vm.expectRevert("Owner release exceeds received");
        merchant.tradeOut(upstreamAccountId, 0, 40e6, "");

        vm.prank(business);
        vm.expectRevert("Business release exceeds received");
        merchant.tradeOut(upstreamAccountId, 0, 60e6, "");

        vm.prank(payer);
        vm.expectRevert("Only account owner or business");
        merchant.tradeOut(upstreamAccountId, 0, 1e6, "");
        assertEq(merchant.ownerReleased(), 0);
        assertEq(merchant.businessReleased(), 0);
    }

    function testMarketFailureRollsBackRelease() public {
        _sale(100e6);

        vm.prank(accountOwner);
        vm.expectRevert("Merchant account not active");
        merchant.tradeOut(999, 0, 1e6, "");

        assertEq(merchant.ownerReleased(), 0);
        assertEq(token.allowance(address(merchant), address(settlement)), 0);
    }

    function testSecondOwnerCannotSellIntoThisSimpleMerchant() public {
        uint256 otherAccountId = _register(anotherOwner, address(merchant), 40000);

        vm.startPrank(payer);
        token.approve(address(settlement), 100e6);
        vm.expectRevert("Wrong account owner");
        market.trade(payer, 0, otherAccountId, 0, 100e6, "");
        vm.stopPrank();

        assertEq(merchant.received(), 0);
        assertEq(merchant.accountId(), 0);
        assertEq(market.netTradeBalance(otherAccountId), 0);
    }

    function testTierChangeRejectsSalesAndReleases() public {
        _sale(100e6);
        vm.prank(accountOwner);
        market.setCapacityMultiplier(merchantAccountId, 30000);

        vm.startPrank(payer);
        token.approve(address(settlement), 100e6);
        vm.expectRevert("Capacity tier changed");
        market.trade(payer, 0, merchantAccountId, 0, 100e6, "");
        vm.stopPrank();

        vm.prank(accountOwner);
        vm.expectRevert("Capacity tier changed");
        merchant.tradeOut(upstreamAccountId, 0, 1e6, "");
        assertEq(merchant.received(), 99e6);
        assertEq(merchant.ownerReleased(), 0);
    }

    function testNewRegistrationCannotReuseOldReceipts() public {
        _sale(100e6);
        market.kickMerchant(merchantAccountId);
        uint256 replacementId = _register(accountOwner, address(merchant), 40000);
        assertTrue(replacementId != merchantAccountId);

        vm.startPrank(payer);
        token.approve(address(settlement), 100e6);
        vm.expectRevert("Market account changed");
        market.trade(payer, 0, replacementId, 0, 100e6, "");
        vm.stopPrank();

        vm.prank(accountOwner);
        vm.expectRevert("Market account changed");
        merchant.tradeOut(upstreamAccountId, 0, 1e6, "");
    }

    function testBusinessChangePreservesItsAccumulatedAllowance() public {
        _sale(100e6);
        address newBusiness = address(0xD00D);
        vm.prank(accountOwner);
        merchant.setBusiness(newBusiness);

        vm.prank(business);
        vm.expectRevert("Only account owner or business");
        merchant.tradeOut(upstreamAccountId, 0, 1e6, "");

        vm.prank(newBusiness);
        merchant.tradeOut(upstreamAccountId, 0, 1e6, "");
        assertEq(merchant.businessReleased(), 1e6);
    }

    function testAdministratorTransferDoesNotTransferEconomicAccount() public {
        _sale(100e6);
        vm.prank(accountOwner);
        merchant.transferOwnership(upstreamOwner);

        vm.prank(upstreamOwner);
        vm.expectRevert("Only account owner or business");
        merchant.tradeOut(upstreamAccountId, 0, 1e6, "");

        vm.prank(accountOwner);
        merchant.tradeOut(upstreamAccountId, 0, 1e6, "");
        assertEq(merchant.ownerReleased(), 1e6);
    }

    function testInvalidInitializationSharesAndRolesRevert() public {
        SimpleMerchantHarness implementation = new SimpleMerchantHarness();

        vm.expectRevert("Invalid release shares");
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                SimpleMerchantHarness.initialize,
                (address(market), accountOwner, address(executor), business, 40000, 6000, 6000)
            )
        );

        vm.expectRevert("Owner and business must differ");
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                SimpleMerchantHarness.initialize,
                (address(market), accountOwner, address(executor), accountOwner, 40000, 4000, 6000)
            )
        );
    }
}
