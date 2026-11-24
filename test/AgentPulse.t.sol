// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentPulse} from "../src/AgentPulse.sol";

contract MockAgentID {
    mapping(address => uint256) public balanceOf;

    function setBalance(address user, uint256 amount) external {
        balanceOf[user] = amount;
    }
}

contract AgentPulseTest is Test {
    MockAgentID internal mock;
    AgentPulse internal pulse;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        mock = new MockAgentID();
        pulse = new AgentPulse(address(mock));
        mock.setBalance(alice, 1);
    }

    function testNonHolderCannotCheckIn() public {
        vm.prank(bob);
        vm.expectRevert(bytes("Agent ID required"));
        pulse.checkIn("gm");
    }

    function testCheckInStreakAndReset() public {
        vm.prank(alice);
        pulse.checkIn("gm agents");
        (uint256 total, uint256 streak,,,,) = pulse.getStats(alice);
        assertEq(total, 1);
        assertEq(streak, 1);
        assertTrue(pulse.checkedInToday(alice));

        // Same day again -> revert
        vm.prank(alice);
        vm.expectRevert(bytes("already checked in today"));
        pulse.checkIn("again");

        // Next day -> streak 2
        vm.warp(block.timestamp + 86400);
        vm.prank(alice);
        pulse.checkIn("day 2");
        (, streak,,,,) = pulse.getStats(alice);
        assertEq(streak, 2);

        // Skip a day -> streak resets, longest kept
        vm.warp(block.timestamp + 2 * 86400);
        vm.prank(alice);
        pulse.checkIn("back again");
        (uint256 total2, uint256 streak2, uint256 longest2, uint256 lastDay, uint256 tier, string memory note2) =
            pulse.getStats(alice);
        assertEq(streak2, 1);
        assertEq(longest2, 2);
        assertEq(total2, 3);
        assertEq(pulse.agentCount(), 1);
        assertEq(pulse.totalPulses(), 3);
    }

    function testBadgeMintedAtThreeDayStreak() public {
        for (uint256 d = 0; d < 3; d++) {
            if (d > 0) vm.warp(block.timestamp + 86400);
            vm.prank(alice);
            pulse.checkIn("streaking");
        }
        assertEq(pulse.highestBadgeTier(alice), 1);
        assertEq(pulse.balanceOf(alice), 1);
        assertEq(pulse.ownerOf(1), alice);
        assertGt(bytes(pulse.tokenURI(1)).length, 100);

        // Soulbound: transfers revert
        vm.prank(alice);
        vm.expectRevert(bytes("soulbound: non-transferable"));
        pulse.transferFrom(alice, bob, 1);
    }

    function testNoteTooLongReverts() public {
        bytes memory long = new bytes(141);
        for (uint256 i = 0; i < 141; i++) long[i] = "a";
        vm.prank(alice);
        vm.expectRevert(bytes("note too long"));
        pulse.checkIn(string(long));
    }

    function testFeedRecordsNote() public {
        vm.prank(alice);
        pulse.checkIn("building in public");
        AgentPulse.Pulse[] memory feed = pulse.getPulses(0, 10);
        assertEq(feed.length, 1);
        assertEq(feed[0].agent, alice);
        assertEq(feed[0].note, "building in public");
        assertEq(feed[0].streak, 1);
    }

    function testProfileAndEndorse() public {
        mock.setBalance(bob, 1);

        vm.prank(alice);
        pulse.registerProfile("Alice Agent", "I watch markets", "trading, research", "https://example.com/alice");
        (AgentPulse.Profile memory p, uint256 endorsements) = pulse.getProfile(alice);
        assertEq(p.name, "Alice Agent");
        assertTrue(p.exists);
        assertEq(endorsements, 0);
        assertEq(pulse.agentCount(), 1);

        // Duplicate registration reverts
        vm.prank(alice);
        vm.expectRevert(bytes("already registered"));
        pulse.registerProfile("Alice Again", "", "", "");

        // Bob registers, then endorses Alice
        vm.prank(bob);
        pulse.registerProfile("Bob Agent", "", "", "");
        vm.prank(bob);
        pulse.endorse(alice);
        (, endorsements) = pulse.getProfile(alice);
        assertEq(endorsements, 1);
        assertTrue(pulse.hasEndorsed(bob, alice));

        // Second endorsement reverts; self-endorsement reverts
        vm.prank(bob);
        vm.expectRevert(bytes("already endorsed"));
        pulse.endorse(alice);
        vm.prank(alice);
        vm.expectRevert(bytes("cannot endorse yourself"));
        pulse.endorse(alice);

        // Non-holder cannot register
        address carol = address(0xCA401);
        vm.prank(carol);
        vm.expectRevert(bytes("Agent ID required"));
        pulse.registerProfile("Carol", "", "", "");

        // Update profile works for the owner of the profile
        vm.prank(alice);
        pulse.updateProfile("Alice Agent v2", "new bio", "", "");
        (AgentPulse.Profile memory p2,) = pulse.getProfile(alice);
        assertEq(p2.name, "Alice Agent v2");
        assertTrue(p2.exists);
    }
}
