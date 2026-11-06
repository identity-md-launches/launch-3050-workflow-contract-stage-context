// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterBadge} from "../src/HamsterBadge.sol";
import {WheelSpinCheckIn} from "../src/WheelSpinCheckIn.sol";

/// @dev Shared leaderboard consistency checks.
abstract contract LeaderboardChecks is Test {
    /// @notice Checks every structural property of the leaderboard against the per-wallet records.
    /// @param wallets Every wallet that may have spun.
    function _checkLeaderboard(WheelSpinCheckIn wheel, address[] memory wallets) internal view {
        WheelSpinCheckIn.LeaderboardEntry[] memory board = wheel.leaderboard();
        uint256 size = board.length;
        uint256 cap = wheel.LEADERBOARD_SIZE();

        assertEq(size, wheel.leaderboardLength(), "length getter");
        assertLe(size, cap, "board larger than its cap");

        uint256 participants = wheel.totalParticipants();
        assertEq(size, participants < cap ? participants : cap, "board must fill before anyone is left out");

        for (uint256 i = 0; i < size; ++i) {
            address account = board[i].account;
            assertTrue(account != address(0), "empty slot");
            assertEq(wheel.rankOf(account), i + 1, "rank does not match position (or duplicate entry)");
            assertEq(board[i].longestStreak, wheel.longestStreak(account), "stale streak on board");
            assertEq(board[i].currentStreak, wheel.currentStreak(account), "current streak");
            assertEq(board[i].totalCheckIns, wheel.totalCheckIns(account), "total");
            assertGt(board[i].longestStreak, 0, "entry that never spun");
            if (i > 0) assertGe(board[i - 1].longestStreak, board[i].longestStreak, "board not sorted");
        }

        uint256 lowest = size == 0 ? 0 : board[size - 1].longestStreak;
        uint256 onBoard = 0;
        for (uint256 i = 0; i < wallets.length; ++i) {
            uint256 rank = wheel.rankOf(wallets[i]);
            if (rank != 0) {
                onBoard += 1;
                assertLe(rank, size, "rank past the end");
                assertEq(board[rank - 1].account, wallets[i], "rank points at another wallet");
            } else if (wheel.totalCheckIns(wallets[i]) != 0) {
                assertEq(size, cap, "participant left out of a board with room");
                assertLe(wheel.longestStreak(wallets[i]), lowest, "left-out wallet beats the last entry");
            }
        }
        assertEq(onBoard, size, "board holds a wallet outside the known set");
    }
}

contract WheelSpinLeaderboardTest is LeaderboardChecks {
    HamsterBadge internal badge;
    WheelSpinCheckIn internal wheel;
    address[] internal wallets;

    uint256 internal constant START = 20_398 days;
    uint256 internal constant WALLETS = 130;

    function setUp() public {
        badge = new HamsterBadge();
        wheel = new WheelSpinCheckIn(address(badge));
        vm.warp(START);
        for (uint256 i = 0; i < WALLETS; ++i) {
            address wallet = address(uint160(0xC0FFEE000 + i));
            wallets.push(wallet);
            vm.prank(wallet);
            badge.mint();
        }
    }

    function _spin(uint256 i) internal {
        vm.prank(wallets[i]);
        wheel.spin();
    }

    function _nextDay() internal {
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    function test_leaderboard_ranksByLongestStreak() public {
        // Day 1: wallets 0, 1, 2 spin. Day 2: 1 and 2. Day 3: only 2.
        _spin(0);
        _spin(1);
        _spin(2);
        _nextDay();
        _spin(1);
        _spin(2);
        _nextDay();
        _spin(2);

        WheelSpinCheckIn.LeaderboardEntry[] memory board = wheel.leaderboard();
        assertEq(board.length, 3);
        assertEq(board[0].account, wallets[2]);
        assertEq(board[0].longestStreak, 3);
        assertEq(board[0].currentStreak, 3);
        assertEq(board[0].totalCheckIns, 3);
        assertEq(board[0].lastSpinDay, START / 1 days + 2);
        assertEq(board[1].account, wallets[1]);
        assertEq(board[1].longestStreak, 2);
        assertEq(board[2].account, wallets[0]);
        assertEq(board[2].longestStreak, 1);

        assertEq(wheel.rankOf(wallets[2]), 1);
        assertEq(wheel.rankOf(wallets[1]), 2);
        assertEq(wheel.rankOf(wallets[0]), 3);
        assertEq(wheel.rankOf(wallets[3]), 0);
        (,,,,, uint256 rank) = wheel.statsOf(wallets[1]);
        assertEq(rank, 2);
        _checkLeaderboard(wheel, wallets);
    }

    function test_leaderboard_keepsBestStreakAfterItLapses() public {
        // Wallet 0 builds a 5-day streak and then stops. Wallet 1 starts later and reaches 3.
        for (uint256 d = 0; d < 5; ++d) {
            _spin(0);
            _nextDay();
        }
        _nextDay();
        for (uint256 d = 0; d < 3; ++d) {
            _spin(1);
            _nextDay();
        }

        WheelSpinCheckIn.LeaderboardEntry[] memory board = wheel.leaderboard();
        assertEq(board[0].account, wallets[0]);
        assertEq(board[0].longestStreak, 5);
        assertEq(board[0].currentStreak, 0, "lapsed streak reads 0 live");
        assertEq(board[1].account, wallets[1]);
        assertEq(board[1].longestStreak, 3);
        assertEq(board[1].currentStreak, 3);

        // A reset spin by wallet 0 does not move it down.
        _spin(0);
        board = wheel.leaderboard();
        assertEq(board[0].account, wallets[0]);
        assertEq(board[0].longestStreak, 5);
        assertEq(board[0].currentStreak, 1);
        _checkLeaderboard(wheel, wallets);
    }

    function test_leaderboard_overtakingMovesAWalletUp() public {
        // Wallets 0..9 spin on day 1 (all tied at 1), then only wallet 9 keeps going.
        for (uint256 i = 0; i < 10; ++i) {
            _spin(i);
        }
        assertEq(wheel.rankOf(wallets[9]), 10);

        _nextDay();
        _spin(9);
        assertEq(wheel.rankOf(wallets[9]), 1, "a 2-day streak leads nine 1-day streaks");
        _checkLeaderboard(wheel, wallets);

        // Wallet 4 catches up to 2 on day 2 as well: it goes above every 1-day wallet, below wallet 9.
        _spin(4);
        assertEq(wheel.rankOf(wallets[9]), 1);
        assertEq(wheel.rankOf(wallets[4]), 2);
        _checkLeaderboard(wheel, wallets);
    }

    function test_leaderboard_isCappedAndEvictsTheLowestStreak() public {
        uint256 cap = wheel.LEADERBOARD_SIZE();

        // Day 1: the first `cap` wallets fill the board.
        for (uint256 i = 0; i < cap; ++i) {
            _spin(i);
        }
        assertEq(wheel.leaderboardLength(), cap);

        // A latecomer with an equal streak does not displace anyone.
        _spin(cap);
        assertEq(wheel.rankOf(wallets[cap]), 0);
        assertEq(wheel.leaderboardLength(), cap);
        assertEq(wheel.totalParticipants(), cap + 1);
        _checkLeaderboard(wheel, wallets);

        // Day 2: the latecomer reaches a 2-day streak and takes the top spot from the 1-day wallets.
        _nextDay();
        address evicted = wheel.leaderboard()[cap - 1].account;
        _spin(cap);
        assertEq(wheel.rankOf(wallets[cap]), 1);
        assertEq(wheel.rankOf(evicted), 0, "the last entry leaves the board");
        assertEq(wheel.leaderboardLength(), cap);
        assertEq(wheel.longestStreak(evicted), 1, "an evicted wallet keeps its own record");
        _checkLeaderboard(wheel, wallets);

        // The evicted wallet can earn its way back with a longer streak.
        vm.prank(evicted);
        wheel.spin();
        assertGt(wheel.rankOf(evicted), 0);
        assertLe(wheel.rankOf(evicted), 2);
        _checkLeaderboard(wheel, wallets);
    }

    function test_leaderboard_floodOfOneDayWalletsCannotDisplaceRealStreaks() public {
        // Ten wallets build a 3-day streak.
        for (uint256 d = 0; d < 3; ++d) {
            for (uint256 i = 0; i < 10; ++i) {
                _spin(i);
            }
            _nextDay();
        }
        // Then every other wallet spins once.
        for (uint256 i = 10; i < WALLETS; ++i) {
            _spin(i);
        }

        for (uint256 i = 0; i < 10; ++i) {
            uint256 rank = wheel.rankOf(wallets[i]);
            assertGt(rank, 0);
            assertLe(rank, 10, "the 3-day wallets hold the top ten");
        }
        assertEq(wheel.leaderboardLength(), wheel.LEADERBOARD_SIZE());
        _checkLeaderboard(wheel, wallets);
    }

    function test_spin_gasStaysBoundedOnAFullBoard() public {
        // Worst case for the board update: a full board of ties, and the last wallet overtakes all of them.
        uint256 cap = wheel.LEADERBOARD_SIZE();
        for (uint256 i = 0; i < cap; ++i) {
            _spin(i);
        }
        _nextDay();

        vm.prank(wallets[cap - 1]);
        uint256 gasBefore = gasleft();
        wheel.spin();
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(wheel.rankOf(wallets[cap - 1]), 1);
        assertLt(gasUsed, 150_000, "spin must stay cheap however full the board is");
    }

    /// forge-config: default.fuzz.runs = 32
    /// @dev Many wallets with different habits spin over many days; the board is checked every day.
    function testFuzz_leaderboard_staysConsistent(uint256 seed, uint8 numDays) public {
        uint256 dayCount = bound(numDays, 5, 25);
        for (uint256 d = 0; d < dayCount; ++d) {
            for (uint256 i = 0; i < WALLETS; ++i) {
                // Each wallet has its own chance (out of 8) of showing up on a given day.
                uint256 diligence = uint256(keccak256(abi.encode(seed, "diligence", i))) % 9;
                uint256 roll = uint256(keccak256(abi.encode(seed, d, i))) % 8;
                if (roll < diligence) _spin(i);
            }
            _checkLeaderboard(wheel, wallets);
            _nextDay();
        }
    }
}

/// @dev Drives random spins, time jumps and badge transfers, and mirrors them in a reference model.
contract WheelHandler is Test {
    HamsterBadge public immutable badge;
    WheelSpinCheckIn public immutable wheel;

    address[] public wallets;
    mapping(address => uint256) public badgeOf; // token id held, 0 if none

    struct Model {
        uint256 lastDay;
        uint256 current;
        uint256 longest;
        uint256 total;
    }

    mapping(address => Model) public model;
    uint256 public modelSpins;
    uint256 public modelParticipants;
    uint256 public rejectedSpins;

    constructor(HamsterBadge badge_, WheelSpinCheckIn wheel_, uint256 count) {
        badge = badge_;
        wheel = wheel_;
        for (uint256 i = 0; i < count; ++i) {
            address wallet = address(uint160(0xD00D000 + i));
            wallets.push(wallet);
            // Four wallets in five hold a badge at the start.
            if (i % 5 != 4) {
                vm.prank(wallet);
                badgeOf[wallet] = badge.mint();
            }
        }
    }

    function allWallets() external view returns (address[] memory) {
        return wallets;
    }

    function liveStreak(address wallet) external view returns (uint256) {
        Model memory m = model[wallet];
        uint256 today = vm.getBlockTimestamp() / 1 days;
        if (m.total == 0 || today > m.lastDay + 1) return 0;
        return m.current;
    }

    /// @notice A run of wallets tries to spin.
    function spinMany(uint256 firstSeed, uint256 countSeed, uint256 stepSeed) external {
        uint256 count = bound(countSeed, 1, 60);
        uint256 step = bound(stepSeed, 1, 7);
        uint256 index = firstSeed % wallets.length;
        for (uint256 i = 0; i < count; ++i) {
            _spin(wallets[index]);
            index = (index + step) % wallets.length;
        }
    }

    function spinOne(uint256 seed) external {
        _spin(wallets[seed % wallets.length]);
    }

    /// @notice Moves time forward by up to three days.
    function warp(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 1, 3 days));
    }

    /// @notice Moves time to the start of the next UTC day (the common "everyone comes back" case).
    function nextDay() external {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
    }

    /// @notice Passes a badge from one wallet to another.
    function transferBadge(uint256 fromSeed, uint256 toSeed) external {
        address from = wallets[fromSeed % wallets.length];
        address to = wallets[toSeed % wallets.length];
        uint256 tokenId = badgeOf[from];
        if (tokenId == 0 || badgeOf[to] != 0 || from == to) return;
        vm.prank(from);
        badge.transferFrom(from, to, tokenId);
        badgeOf[from] = 0;
        badgeOf[to] = tokenId;
    }

    function _spin(address wallet) private {
        Model storage m = model[wallet];
        uint256 today = vm.getBlockTimestamp() / 1 days;

        if (badgeOf[wallet] == 0) {
            rejectedSpins += 1;
            vm.prank(wallet);
            vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.NotBadgeHolder.selector, wallet));
            wheel.spin();
            return;
        }
        if (m.total != 0 && m.lastDay == today) {
            rejectedSpins += 1;
            vm.prank(wallet);
            vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.AlreadySpunToday.selector, wallet, today));
            wheel.spin();
            return;
        }

        if (m.total == 0) modelParticipants += 1;
        m.current = (m.total != 0 && m.lastDay + 1 == today) ? m.current + 1 : 1;
        if (m.current > m.longest) m.longest = m.current;
        m.total += 1;
        m.lastDay = today;
        modelSpins += 1;

        vm.prank(wallet);
        uint256 streak = wheel.spin();
        assertEq(streak, m.current, "returned streak");
    }
}

contract WheelSpinInvariantTest is LeaderboardChecks {
    HamsterBadge internal badge;
    WheelSpinCheckIn internal wheel;
    WheelHandler internal handler;

    function setUp() public {
        badge = new HamsterBadge();
        wheel = new WheelSpinCheckIn(address(badge));
        vm.warp(20_398 days);
        handler = new WheelHandler(badge, wheel, 140);

        // Spinning and day changes are listed more than once so that streaks get a chance to grow.
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = WheelHandler.spinMany.selector;
        selectors[1] = WheelHandler.spinMany.selector;
        selectors[2] = WheelHandler.spinMany.selector;
        selectors[3] = WheelHandler.spinOne.selector;
        selectors[4] = WheelHandler.warp.selector;
        selectors[5] = WheelHandler.nextDay.selector;
        selectors[6] = WheelHandler.nextDay.selector;
        selectors[7] = WheelHandler.transferBadge.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_recordsMatchModelAndBoardIsConsistent() public view {
        address[] memory wallets = handler.allWallets();

        assertEq(wheel.totalSpins(), handler.modelSpins(), "total spins");
        assertEq(wheel.totalParticipants(), handler.modelParticipants(), "participants");

        uint256 sumOfTotals = 0;
        for (uint256 i = 0; i < wallets.length; ++i) {
            address wallet = wallets[i];
            (uint256 lastDay, uint256 current, uint256 longest, uint256 total) = handler.model(wallet);
            current; // the stored streak is checked through its live value below

            assertEq(wheel.totalCheckIns(wallet), total, "total check-ins");
            assertEq(wheel.longestStreak(wallet), longest, "longest streak");
            assertEq(wheel.currentStreak(wallet), handler.liveStreak(wallet), "live streak");
            if (total != 0) assertEq(wheel.lastSpinDay(wallet), lastDay, "last spin day");

            assertLe(wheel.currentStreak(wallet), longest, "current above longest");
            assertLe(longest, total, "longest above total");
            sumOfTotals += total;
        }
        assertEq(sumOfTotals, wheel.totalSpins(), "per-wallet totals add up to the global count");

        _checkLeaderboard(wheel, wallets);

        assertEq(address(wheel).balance, 0, "check-in contract holds ETH");
        assertEq(address(badge).balance, 0, "badge contract holds ETH");
    }
}
