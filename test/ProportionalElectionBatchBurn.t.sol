// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/RightsToken/GenesisSeatToken.sol";
import "../src/RightsToken/ProportionalElection.sol";
import "../src/RightsToken/SeatToken.sol";
import "../src/RightsToken/SeatTokenFactory.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ProportionalElectionBatchBurnTest is Test {
    ProportionalElection private election;
    SeatToken private activeToken;

    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant OUTSIDER = address(0xBAD);

    event SeatBurned(
        uint256 indexed roundId,
        address indexed from,
        uint256 amount
    );

    event SeatBurnSkipped(uint256 indexed roundId, address indexed from, uint256 amount);

    function _roundIds(uint256 length, uint256 roundId) private pure returns (uint256[] memory ids) {
        ids = new uint256[](length);
        for (uint256 i; i < length; ++i) ids[i] = roundId;
    }

    function setUp() public {
        vm.warp(2 * 365 days);

        SeatTokenFactory factory = new SeatTokenFactory();
        GenesisSeatToken genesis = new GenesisSeatToken(
            "Council Seat 0",
            "CS",
            address(this)
        );

        ProportionalElection implementation = new ProportionalElection();
        election = ProportionalElection(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        ProportionalElection.initialize,
                        (address(factory), address(this), address(genesis))
                    )
                )
            )
        );

        genesis.setMinter(address(election));
        factory.setElectionContract(address(election));

        election.mint(ALICE, 100 ether);
        election.mint(BOB, 200 ether);
        vm.warp(election.genesisTime() + 3 * election.CYCLE_DURATION());
        vm.roll(block.number + 1);

        (address token, ) = election.rounds(2);
        activeToken = SeatToken(token);
    }

    function testBatchBurnBurnsEveryAccountAndUpdatesVotes() public {
        address[] memory accounts = new address[](2);
        accounts[0] = ALICE;
        accounts[1] = BOB;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 30 ether;
        amounts[1] = 50 ether;

        vm.expectEmit(true, true, false, true, address(election));
        emit SeatBurned(2, ALICE, 30 ether);
        vm.expectEmit(true, true, false, true, address(election));
        emit SeatBurned(2, BOB, 50 ether);

        election.batchBurn(accounts, amounts, _roundIds(accounts.length, 2));

        assertEq(activeToken.balanceOf(ALICE), 70 ether);
        assertEq(activeToken.balanceOf(BOB), 150 ether);
        assertEq(activeToken.getVotes(ALICE), 70 ether);
        assertEq(activeToken.getVotes(BOB), 150 ether);
        assertEq(activeToken.totalSupply(), 220 ether);
    }

    function testBatchBurnSkipsFailedItemAndContinues() public {
        address[] memory accounts = new address[](3);
        accounts[0] = ALICE;
        accounts[1] = OUTSIDER;
        accounts[2] = BOB;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 30 ether;
        amounts[1] = 1 ether;
        amounts[2] = 50 ether;

        vm.expectEmit(true, true, false, true, address(election));
        emit SeatBurned(2, ALICE, 30 ether);
        vm.expectEmit(true, true, false, true, address(election));
        emit SeatBurnSkipped(2, OUTSIDER, 1 ether);
        vm.expectEmit(true, true, false, true, address(election));
        emit SeatBurned(2, BOB, 50 ether);

        election.batchBurn(accounts, amounts, _roundIds(accounts.length, 2));

        assertEq(activeToken.balanceOf(ALICE), 70 ether);
        assertEq(activeToken.balanceOf(OUTSIDER), 0);
        assertEq(activeToken.balanceOf(BOB), 150 ether);
        assertEq(activeToken.totalSupply(), 220 ether);
    }

    function testBatchBurnCanMixPendingAndFirstActiveRounds() public {
        election.mint(OUTSIDER, 80 ether);
        (address pendingToken,) = election.rounds(3);

        address[] memory accounts = new address[](2);
        accounts[0] = ALICE;
        accounts[1] = OUTSIDER;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 30 ether;
        amounts[1] = 20 ether;

        uint256[] memory roundIds = new uint256[](2);
        roundIds[0] = 2;
        roundIds[1] = 3;

        vm.expectEmit(true, true, false, true, address(election));
        emit SeatBurned(2, ALICE, 30 ether);
        vm.expectEmit(true, true, false, true, address(election));
        emit SeatBurned(3, OUTSIDER, 20 ether);

        election.batchBurn(accounts, amounts, roundIds);

        assertEq(activeToken.balanceOf(ALICE), 70 ether);
        assertEq(SeatToken(pendingToken).balanceOf(OUTSIDER), 60 ether);
        assertEq(election.getVotes(OUTSIDER), 0);
    }

    function testBatchBurnSkipsIneligibleRoundAndContinues() public {
        address[] memory accounts = new address[](3);
        accounts[0] = ALICE;
        accounts[1] = BOB;
        accounts[2] = BOB;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 30 ether;
        amounts[1] = 50 ether;
        amounts[2] = 50 ether;

        uint256[] memory roundIds = _roundIds(3, 2);
        roundIds[1] = 4;

        vm.expectEmit(true, true, false, true, address(election));
        emit SeatBurned(2, ALICE, 30 ether);
        vm.expectEmit(true, true, false, true, address(election));
        emit SeatBurnSkipped(4, BOB, 50 ether);
        vm.expectEmit(true, true, false, true, address(election));
        emit SeatBurned(2, BOB, 50 ether);

        election.batchBurn(accounts, amounts, roundIds);

        assertEq(activeToken.balanceOf(ALICE), 70 ether);
        assertEq(activeToken.balanceOf(BOB), 150 ether);
        assertEq(activeToken.totalSupply(), 220 ether);
    }

    function testBatchBurnRejectsRoundIdLengthMismatch() public {
        address[] memory accounts = new address[](2);
        accounts[0] = ALICE;
        accounts[1] = BOB;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 30 ether;
        amounts[1] = 50 ether;

        uint256[] memory roundIds = _roundIds(1, 2);
        vm.expectRevert(SeatToken.BatchLengthMismatch.selector);
        election.batchBurn(accounts, amounts, roundIds);

        assertEq(activeToken.balanceOf(ALICE), 100 ether);
        assertEq(activeToken.balanceOf(BOB), 200 ether);
    }

    function testBatchBurnRejectsMismatchedLengths() public {
        address[] memory accounts = new address[](2);
        accounts[0] = ALICE;
        accounts[1] = BOB;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 30 ether;

        vm.expectRevert(SeatToken.BatchLengthMismatch.selector);
        election.batchBurn(accounts, amounts, _roundIds(accounts.length, 2));

        assertEq(activeToken.balanceOf(ALICE), 100 ether);
        assertEq(activeToken.balanceOf(BOB), 200 ether);
    }

    function testBatchBurnIsOwnerOnly() public {
        address[] memory accounts = new address[](1);
        accounts[0] = ALICE;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.prank(OUTSIDER);
        vm.expectRevert();
        election.batchBurn(accounts, amounts, _roundIds(accounts.length, 2));
    }
}
