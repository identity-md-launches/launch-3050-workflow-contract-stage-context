// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterBadge} from "../src/HamsterBadge.sol";
import {WheelSpinCheckIn} from "../src/WheelSpinCheckIn.sol";

contract WheelSpinCheckInTest is Test {
    HamsterBadge internal badge;
    WheelSpinCheckIn internal wheel;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    /// @dev 2026-11-06 00:00:00 UTC, the start of UTC day 20,398.
    uint256 internal constant START = 20_398 days;
    uint256 internal constant START_DAY = 20_398;

    event Spun(
        address indexed account,
        uint256 indexed day,
        uint256 currentStreak,
        uint256 longestStreak,
        uint256 totalCheckIns
    );

    function setUp() public {
        badge = new HamsterBadge();
        wheel = new WheelSpinCheckIn(address(badge));
        vm.warp(START);

        vm.prank(alice);
        badge.mint();
        vm.prank(bob);
        badge.mint();
    }

    function _spin(address who) internal returns (uint256) {
        vm.prank(who);
        return wheel.spin();
    }

    function _nextDay() internal {
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    function _assertStats(address who, uint256 current, uint256 longest, uint256 total) internal view {
        assertEq(wheel.currentStreak(who), current, "current streak");
        assertEq(wheel.longestStreak(who), longest, "longest streak");
        assertEq(wheel.totalCheckIns(who), total, "total check-ins");
        (uint256 c, uint256 l, uint256 t,,,) = wheel.statsOf(who);
        assertEq(c, current, "statsOf current");
        assertEq(l, longest, "statsOf longest");
        assertEq(t, total, "statsOf total");
    }

    // ─────────────────────────────── deployment ───────────────────────────────

    function test_constructor_storesBadgeAndStartsEmpty() public view {
        assertEq(address(wheel.badge()), address(badge));
        assertEq(wheel.LEADERBOARD_SIZE(), 100);
        assertEq(wheel.DAY(), 86_400);
        assertEq(wheel.totalParticipants(), 0);
        assertEq(wheel.totalSpins(), 0);
        assertEq(wheel.leaderboardLength(), 0);
        assertEq(wheel.leaderboard().length, 0);
    }

    function test_constructor_revertsOnZeroBadge() public {
        vm.expectRevert(WheelSpinCheckIn.ZeroBadgeAddress.selector);
        new WheelSpinCheckIn(address(0));
    }

    function test_constructor_doesNotNeedBadgeToExistYet() public {
        // The launch may deploy the contracts before the badge has code; nothing is called at construction.
        address notDeployedYet = makeAddr("future badge");
        WheelSpinCheckIn early = new WheelSpinCheckIn(notDeployedYet);
        assertEq(address(early.badge()), notDeployedYet);

        // Until the badge exists, spinning fails instead of silently succeeding.
        vm.prank(alice);
        vm.expectRevert();
        early.spin();
        assertEq(early.totalSpins(), 0);
    }

    function test_contract_hasNoOwnerAndTakesNoEth() public {
        (bool ok,) = address(wheel).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner()");

        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        (ok,) = address(wheel).call{value: 1 wei}("");
        assertFalse(ok, "no receive function");
        (ok,) = address(wheel).call{value: 1 wei}(abi.encodeCall(WheelSpinCheckIn.spin, ()));
        assertFalse(ok, "spin is not payable");
        vm.stopPrank();
        assertEq(address(wheel).balance, 0);
        assertEq(wheel.totalSpins(), 0);
    }

    // ───────────────────────────────── spinning ────────────────────────────────

    function test_spin_firstSpinStartsStreakAtOne() public {
        assertTrue(wheel.canSpin(alice));
        assertFalse(wheel.hasSpunToday(alice));

        vm.expectEmit(true, true, true, true, address(wheel));
        emit Spun(alice, START_DAY, 1, 1, 1);
        uint256 streak = _spin(alice);

        assertEq(streak, 1);
        _assertStats(alice, 1, 1, 1);
        assertEq(wheel.lastSpinDay(alice), START_DAY);
        assertTrue(wheel.hasSpunToday(alice));
        assertFalse(wheel.canSpin(alice));
        assertEq(wheel.totalParticipants(), 1);
        assertEq(wheel.totalSpins(), 1);
    }

    function test_spin_revertsForWalletWithoutBadge() public {
        assertFalse(wheel.canSpin(carol));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.NotBadgeHolder.selector, carol));
        wheel.spin();

        _assertStats(carol, 0, 0, 0);
        assertEq(wheel.totalParticipants(), 0);
        assertEq(wheel.totalSpins(), 0);
    }

    function test_spin_revertsOnSecondSpinTheSameDay() public {
        _spin(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.AlreadySpunToday.selector, alice, START_DAY));
        wheel.spin();

        // Still the same UTC day one second before midnight.
        vm.warp(START + 1 days - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.AlreadySpunToday.selector, alice, START_DAY));
        wheel.spin();

        _assertStats(alice, 1, 1, 1);
        assertEq(wheel.totalSpins(), 1);
    }

    function test_spin_newUtcDayStartsExactlyAtMidnight() public {
        vm.warp(START + 1 days - 1);
        _spin(alice);
        assertEq(wheel.nextDayStartsAt(), START + 1 days);

        // One second later it is a new UTC day: the spin is allowed and continues the streak.
        vm.warp(START + 1 days);
        assertEq(wheel.currentDay(), START_DAY + 1);
        assertTrue(wheel.canSpin(alice));
        assertEq(_spin(alice), 2);
        _assertStats(alice, 2, 2, 2);
    }

    function test_spin_consecutiveDaysGrowTheStreak() public {
        for (uint256 day = 1; day <= 7; ++day) {
            vm.expectEmit(true, true, true, true, address(wheel));
            emit Spun(alice, START_DAY + day - 1, day, day, day);
            assertEq(_spin(alice), day);
            _assertStats(alice, day, day, day);
            _nextDay();
        }
        assertEq(wheel.totalParticipants(), 1);
        assertEq(wheel.totalSpins(), 7);
    }

    function test_spin_missedDayResetsStreakButKeepsLongestAndTotal() public {
        _spin(alice);
        _nextDay();
        _spin(alice);
        _nextDay();
        _spin(alice);
        _assertStats(alice, 3, 3, 3);

        // The day after the last spin the streak is still alive (today's spin is simply pending).
        _nextDay();
        _assertStats(alice, 3, 3, 3);
        assertTrue(wheel.canSpin(alice));

        // A whole UTC day passes without a spin: the live streak reads 0 before any transaction.
        _nextDay();
        _assertStats(alice, 0, 3, 3);

        // The next spin starts over at 1; longest and total are kept.
        vm.expectEmit(true, true, true, true, address(wheel));
        emit Spun(alice, START_DAY + 4, 1, 3, 4);
        assertEq(_spin(alice), 1);
        _assertStats(alice, 1, 3, 4);

        // Rebuild past the old record.
        for (uint256 i = 0; i < 3; ++i) {
            _nextDay();
            _spin(alice);
        }
        _assertStats(alice, 4, 4, 7);
    }

    function test_spin_longGapResetsStreak() public {
        _spin(alice);
        vm.warp(START + 400 days);
        _assertStats(alice, 0, 1, 1);
        assertEq(_spin(alice), 1);
        _assertStats(alice, 1, 1, 2);
    }

    function test_spin_walletsAreIndependent() public {
        _spin(alice);
        _nextDay();
        _spin(alice);
        _spin(bob);

        _assertStats(alice, 2, 2, 2);
        _assertStats(bob, 1, 1, 1);
        assertEq(wheel.totalParticipants(), 2);
        assertEq(wheel.totalSpins(), 3);
    }

    function test_spin_worksOnDayZeroOfTheEpoch() public {
        // A fresh local chain starts at timestamp 1, where the day number is 0.
        vm.warp(1);
        assertEq(wheel.currentDay(), 0);
        assertFalse(wheel.hasSpunToday(alice));
        _spin(alice);
        assertTrue(wheel.hasSpunToday(alice));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.AlreadySpunToday.selector, alice, 0));
        wheel.spin();

        vm.warp(1 days);
        assertEq(_spin(alice), 2);
    }

    // ─────────────────────────────── badge gating ──────────────────────────────

    function test_spin_requiresHoldingABadgeAtSpinTime() public {
        _spin(alice);
        _nextDay();

        // Alice gives her badge away: she can no longer spin, Carol now can.
        vm.prank(alice);
        badge.transferFrom(alice, carol, 1);

        assertFalse(wheel.canSpin(alice));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.NotBadgeHolder.selector, alice));
        wheel.spin();

        assertEq(_spin(carol), 1);

        // Alice's history stays hers; Carol starts from scratch.
        _assertStats(alice, 1, 1, 1);
        _assertStats(carol, 1, 1, 1);

        // Getting a badge back in time lets Alice continue her streak.
        vm.prank(carol);
        badge.transferFrom(carol, alice, 1);
        assertEq(_spin(alice), 2);
    }

    function test_spin_failedSpinDoesNotCountAsTodaysSpin() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.NotBadgeHolder.selector, carol));
        wheel.spin();

        vm.prank(carol);
        badge.mint();
        assertEq(_spin(carol), 1);
    }

    // ────────────────────────────────── fuzz ───────────────────────────────────

    /// @dev Replays a random schedule of spin attempts against a simple reference model.
    function testFuzz_spin_matchesReferenceModel(uint32[24] memory gaps) public {
        uint256 lastDay;
        uint256 current;
        uint256 longest;
        uint256 total;

        for (uint256 i = 0; i < gaps.length; ++i) {
            // Move forward by 0 seconds to 3 days.
            vm.warp(vm.getBlockTimestamp() + (gaps[i] % (3 days + 1)));
            uint256 today = vm.getBlockTimestamp() / 1 days;

            if (total != 0 && lastDay == today) {
                vm.prank(alice);
                vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.AlreadySpunToday.selector, alice, today));
                wheel.spin();
            } else {
                current = (total != 0 && lastDay + 1 == today) ? current + 1 : 1;
                if (current > longest) longest = current;
                total += 1;
                lastDay = today;
                assertEq(_spin(alice), current);
            }

            _assertStats(alice, current, longest, total);
            assertEq(wheel.lastSpinDay(alice), lastDay);
            assertEq(wheel.totalSpins(), total);
            assertLe(wheel.currentStreak(alice), wheel.longestStreak(alice));
            assertLe(wheel.longestStreak(alice), wheel.totalCheckIns(alice));
        }
    }

    function testFuzz_spin_onlyOncePerUtcDay(uint256 first, uint256 second) public {
        first = bound(first, START, START + 3650 days);
        second = bound(second, first, first + 3 days);

        vm.warp(first);
        _spin(alice);
        vm.warp(second);

        if (second / 1 days == first / 1 days) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.AlreadySpunToday.selector, alice, first / 1 days));
            wheel.spin();
            assertEq(wheel.totalCheckIns(alice), 1);
        } else {
            uint256 expected = second / 1 days == first / 1 days + 1 ? 2 : 1;
            assertEq(_spin(alice), expected);
            assertEq(wheel.totalCheckIns(alice), 2);
        }
    }

    function testFuzz_spin_nonHolderAlwaysReverts(address stranger, uint256 when) public {
        vm.assume(badge.balanceOf(stranger == address(0) ? carol : stranger) == 0);
        vm.assume(stranger != address(0));
        vm.warp(bound(when, START, START + 3650 days));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.NotBadgeHolder.selector, stranger));
        wheel.spin();
    }
}
