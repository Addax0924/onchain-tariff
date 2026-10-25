// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/RightsToken/GenesisSeatToken.sol";
import "../src/RightsToken/ProportionalElection.sol";
import "../src/RightsToken/SeatToken.sol";
import "../src/RightsToken/SeatTokenFactory.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ProportionalElectionActivationTest is Test {
    ProportionalElection private election;

    address private constant GENESIS_HOLDER = address(0xA0);
    address private constant FIRST_HOLDER = address(0xA1);
    address private constant SECOND_HOLDER = address(0xA2);

    function setUp() public {
        vm.warp(2 * 365 days);

        SeatTokenFactory factory = new SeatTokenFactory();
        GenesisSeatToken genesis = new GenesisSeatToken("Council Seat 0", "CS", address(this));
        genesis.mint(GENESIS_HOLDER, 100 ether);

        election = ProportionalElection(
            address(
                new ERC1967Proxy(
                    address(new ProportionalElection()),
                    abi.encodeCall(
                        ProportionalElection.initialize,
                        (address(factory), address(this), address(genesis))
                    )
                )
            )
        );
        genesis.setMinter(address(election));
        factory.setElectionContract(address(election));
    }

    function testCurrentRoundMintsOnlyVoteStartingNextRound() public {
        uint256 firstBoundary = block.timestamp + 365 days;
        assertEq(election.currentRoundId(), 2);
        assertEq(election.getVotes(GENESIS_HOLDER), 100 ether);

        election.mint(FIRST_HOLDER, 50 ether);
        assertEq(election.getVotes(FIRST_HOLDER), 0);

        vm.warp(firstBoundary - 1);
        assertEq(election.getVotes(FIRST_HOLDER), 0);

        vm.warp(firstBoundary);
        assertEq(election.currentRoundId(), 3);
        assertEq(election.getVotes(FIRST_HOLDER), 100 ether);

        election.mint(SECOND_HOLDER, 50 ether);
        assertEq(election.getVotes(SECOND_HOLDER), 0);
        vm.warp(firstBoundary + 365 days);
        assertEq(election.getVotes(SECOND_HOLDER), 100 ether);
    }

    function testLateRoundMintActivatesAtTheSameBoundary() public {
        uint256 firstBoundary = block.timestamp + 365 days;
        vm.warp(firstBoundary - 1);
        election.mint(FIRST_HOLDER, 50 ether);
        assertEq(election.getVotes(FIRST_HOLDER), 0);

        vm.warp(firstBoundary);
        assertEq(election.getVotes(FIRST_HOLDER), 100 ether);
    }

    function testPendingSeatsCanBePartiallyBurned() public {
        uint256 firstBoundary = block.timestamp + 365 days;
        election.mint(FIRST_HOLDER, 100 ether);
        election.mint(SECOND_HOLDER, 100 ether);
        (address token,) = election.rounds(2);

        election.burn(FIRST_HOLDER, 40 ether, 2);
        assertEq(SeatToken(token).balanceOf(FIRST_HOLDER), 60 ether);
        assertEq(SeatToken(token).balanceOf(SECOND_HOLDER), 100 ether);
        assertEq(election.getVotes(FIRST_HOLDER), 0);

        vm.warp(firstBoundary);
        assertEq(election.getVotes(FIRST_HOLDER), 375e17);
        assertEq(election.getVotes(SECOND_HOLDER), 625e17);
    }

    function testFirstActiveYearCanBurnButSecondActiveYearCannot() public {
        uint256 firstBoundary = block.timestamp + 365 days;
        election.mint(FIRST_HOLDER, 100 ether);
        (address token,) = election.rounds(2);

        vm.warp(firstBoundary);
        election.burn(FIRST_HOLDER, 25 ether, 2);
        assertEq(SeatToken(token).balanceOf(FIRST_HOLDER), 75 ether);

        vm.warp(firstBoundary + 365 days);
        assertEq(election.getVotes(FIRST_HOLDER), 100 ether);
        vm.expectRevert("ProportionalElection: round not burnable");
        election.burn(FIRST_HOLDER, 1 ether, 2);
    }

    function testGenesisAndFutureRoundsCannotBeBurned() public {
        election.mint(FIRST_HOLDER, 10 ether);

        vm.expectRevert("ProportionalElection: round not burnable");
        election.burn(GENESIS_HOLDER, 1 ether, 0);
        vm.expectRevert("ProportionalElection: round not burnable");
        election.burn(FIRST_HOLDER, 1 ether, 3);
    }

    function testPendingRoundDoesNotAffectHistoricalVotesOrSupply() public {
        uint256 firstBoundary = block.timestamp + 365 days;
        election.mint(FIRST_HOLDER, 50 ether);

        uint256 beforeBoundary = firstBoundary - 1;
        vm.warp(firstBoundary);
        assertEq(election.getPastVotes(FIRST_HOLDER, beforeBoundary), 0);
        assertEq(election.getPastTotalSupply(beforeBoundary), 100 ether);

        vm.warp(firstBoundary + 1);
        assertEq(election.getPastVotes(FIRST_HOLDER, firstBoundary), 100 ether);
        assertEq(election.getPastTotalSupply(firstBoundary), 200 ether);
        assertEq(election.getPastTotalSupply(beforeBoundary), 100 ether);
    }
}
