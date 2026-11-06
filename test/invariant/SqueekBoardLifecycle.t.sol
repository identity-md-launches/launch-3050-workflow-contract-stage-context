// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterBadge} from "src/HamsterBadge.sol";
import {WheelSpinCheckIn} from "src/WheelSpinCheckIn.sol";

/// @dev Closed actor set: all tokens stay within these actors, including actors with several tokens.
/// Ghost ownership and approvals are updated only after successful calls. Spin history is an
/// append-only list of actual successful days, not a copy of the contract's streak counters.
contract SqueekBoardLifecycleHandler is Test {
    uint256 public constant ACTORS = 12;
    HamsterBadge public immutable badge;
    WheelSpinCheckIn public immutable wheel;

    address[] private owners;
    address[] private approvals;
    mapping(address => bool) private minted;
    mapping(address => mapping(address => bool)) private operators;
    mapping(address => uint256[]) private spinDays;

    uint256 public successfulMints;
    uint256 public rejectedMints;
    uint256 public successfulTransfers;
    uint256 public rejectedTransfers;
    uint256 public successfulApprovals;
    uint256 public rejectedApprovals;
    uint256 public successfulSpins;
    uint256 public rejectedSpins;

    struct History {
        uint256 current;
        uint256 longest;
        uint256 total;
        uint256 lastDay;
        bool spunToday;
    }

    constructor(HamsterBadge badge_, WheelSpinCheckIn wheel_) {
        badge = badge_;
        wheel = wheel_;
        owners.push(address(0)); // token ids start at 1
        approvals.push(address(0));
        for (uint256 i; i < ACTORS / 2; ++i) {
            mint(i);
        }
    }

    function actor(uint256 seed) public pure returns (address) {
        return address(uint160(0xC0DE0000 + seed % ACTORS));
    }

    function mint(uint256 actorSeed) public {
        address account = actor(actorSeed);
        if (minted[account]) {
            ++rejectedMints;
            vm.prank(account);
            vm.expectRevert(abi.encodeWithSelector(HamsterBadge.AlreadyMinted.selector, account));
            badge.mint();
            return;
        }
        vm.prank(account);
        uint256 tokenId = badge.mint();
        assertEq(tokenId, owners.length, "mint must allocate the next id");
        owners.push(account);
        approvals.push(address(0));
        minted[account] = true;
        ++successfulMints;
    }

    /// @dev Owner calls exercise grants/revocations; arbitrary callers exercise authorization failures.
    function approve(uint256 tokenSeed, uint256 toSeed, uint256 callerSeed, bool asOwner) external {
        uint256 tokenId = _token(tokenSeed);
        address owner = owners[tokenId];
        address caller = asOwner ? owner : actor(callerSeed);
        address to = toSeed % (ACTORS + 1) == ACTORS ? address(0) : actor(toSeed);
        if (caller != owner && !operators[owner][caller]) {
            ++rejectedApprovals;
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, caller));
            badge.approve(to, tokenId);
            return;
        }
        vm.prank(caller);
        badge.approve(to, tokenId);
        approvals[tokenId] = to;
        ++successfulApprovals;
    }

    function setOperator(uint256 ownerSeed, uint256 operatorSeed, bool enabled) external {
        address owner = actor(ownerSeed);
        address operator = actor(operatorSeed);
        vm.prank(owner);
        badge.setApprovalForAll(operator, enabled);
        operators[owner][operator] = enabled;
    }

    /// @dev Route 0 = owner, 1 = token-approved account if any, 2 = arbitrary actor.
    /// Includes self-transfers and transfers to wallets that already own other badges.
    function transfer(uint256 tokenSeed, uint256 toSeed, uint256 callerSeed, uint8 route, bool safe) external {
        uint256 tokenId = _token(tokenSeed);
        address owner = owners[tokenId];
        address to = actor(toSeed);
        address caller = actor(callerSeed);
        if (route % 3 == 0) caller = owner;
        if (route % 3 == 1 && approvals[tokenId] != address(0)) caller = approvals[tokenId];

        bool allowed = caller == owner || approvals[tokenId] == caller || operators[owner][caller];
        if (!allowed) {
            ++rejectedTransfers;
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, caller, tokenId));
        }
        vm.prank(caller);
        if (safe) badge.safeTransferFrom(owner, to, tokenId);
        else badge.transferFrom(owner, to, tokenId);
        if (allowed) {
            owners[tokenId] = to;
            approvals[tokenId] = address(0);
            ++successfulTransfers;
        }
    }

    function spin(uint256 actorSeed) external {
        _spin(actor(actorSeed));
    }

    function spinMany(uint256 firstSeed, uint256 countSeed) external {
        uint256 count = bound(countSeed, 1, ACTORS);
        uint256 first = firstSeed % ACTORS;
        for (uint256 i; i < count; ++i) {
            _spin(actor(first + i));
        }
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 3 days));
    }

    function nextDay() external {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
    }

    function assertState() external view {
        _assertBadges();
        _assertHistories();
        _assertLeaderboard();
    }

    function _token(uint256 seed) private view returns (uint256) {
        return 1 + seed % (owners.length - 1);
    }

    function _balance(address account) private view returns (uint256 count) {
        for (uint256 id = 1; id < owners.length; ++id) {
            if (owners[id] == account) ++count;
        }
    }

    function _spin(address account) private {
        uint256 today = vm.getBlockTimestamp() / 1 days;
        uint256[] storage days_ = spinDays[account];
        if (_balance(account) == 0) {
            ++rejectedSpins;
            vm.prank(account);
            vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.NotBadgeHolder.selector, account));
            wheel.spin();
        } else if (days_.length != 0 && days_[days_.length - 1] == today) {
            ++rejectedSpins;
            vm.prank(account);
            vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.AlreadySpunToday.selector, account, today));
            wheel.spin();
        } else {
            vm.prank(account);
            uint256 returnedStreak = wheel.spin();
            days_.push(today);
            ++successfulSpins;
            assertEq(returnedStreak, _history(account).current, "spin return disagrees with history");
        }
    }

    /// @dev Derive streaks from contiguous intervals in the successful-day log. Production uses
    /// packed counters and incremental updates; this oracle can reconstruct the entire history.
    function _history(address account) private view returns (History memory h) {
        uint256[] storage days_ = spinDays[account];
        h.total = days_.length;
        if (h.total == 0) return h;
        uint256 intervalStart;
        for (uint256 i; i < h.total; ++i) {
            if (i != 0 && days_[i] != days_[i - 1] + 1) intervalStart = i;
            uint256 intervalLength = i - intervalStart + 1;
            if (intervalLength > h.longest) h.longest = intervalLength;
        }
        h.lastDay = days_[h.total - 1];
        uint256 today = vm.getBlockTimestamp() / 1 days;
        h.spunToday = h.lastDay == today;
        if (today - h.lastDay <= 1) h.current = h.total - intervalStart;
    }

    function _assertBadges() private view {
        uint256 supply = owners.length - 1;
        assertEq(badge.totalSupply(), supply, "supply vs successful mint log");
        assertEq(badge.totalSupply(), successfulMints, "mint count");
        assertLe(supply, badge.MAX_SUPPLY());
        assertEq(badge.remainingSupply() + supply, badge.MAX_SUPPLY());
        uint256 sumBalances;
        uint256 mintCount;
        for (uint256 i; i < ACTORS; ++i) {
            address account = actor(i);
            uint256 expectedBalance = _balance(account);
            assertEq(badge.balanceOf(account), expectedBalance, "balance vs ownership log");
            assertEq(badge.hasMinted(account), minted[account], "mint right cannot be restored by transfers");
            assertEq(badge.canMint(account), !minted[account] && supply < badge.MAX_SUPPLY());
            sumBalances += badge.balanceOf(account);
            if (minted[account]) ++mintCount;
            for (uint256 j; j < ACTORS; ++j) {
                address operator = actor(j);
                assertEq(badge.isApprovedForAll(account, operator), operators[account][operator], "operator scope");
            }
        }
        assertEq(sumBalances, supply, "every token is accounted for exactly once");
        assertEq(mintCount, supply, "one mint per distinct wallet");
        for (uint256 id = 1; id <= supply; ++id) {
            assertEq(badge.ownerOf(id), owners[id], "owner changed without an authorized transfer");
            assertEq(badge.getApproved(id), approvals[id], "stale or unauthorized token approval");
        }
    }

    function _assertHistories() private view {
        uint256 spins;
        uint256 participants;
        for (uint256 i; i < ACTORS; ++i) {
            address account = actor(i);
            History memory h = _history(account);
            (uint256 current, uint256 longest, uint256 total, uint256 lastDay, bool spunToday, uint256 rank) =
                wheel.statsOf(account);
            assertEq(current, h.current, "stats current vs successful days");
            assertEq(longest, h.longest, "stats longest vs successful days");
            assertEq(total, h.total, "stats total vs successful days");
            assertEq(lastDay, h.lastDay, "stats last day vs successful days");
            assertEq(spunToday, h.spunToday, "stats daily gate");
            assertEq(rank, wheel.rankOf(account), "stats rank");
            assertEq(wheel.currentStreak(account), h.current);
            assertEq(wheel.longestStreak(account), h.longest);
            assertEq(wheel.totalCheckIns(account), h.total);
            assertEq(wheel.lastSpinDay(account), h.lastDay);
            assertEq(wheel.hasSpunToday(account), h.spunToday);
            assertEq(wheel.canSpin(account), _balance(account) > 0 && !h.spunToday, "holder and daily eligibility");
            if (h.total != 0) {
                ++participants;
                assertGt(rank, 0, "every participant fits this small board");
            } else {
                assertEq(rank, 0, "nonparticipant ranked");
            }
            spins += h.total;
        }
        assertEq(wheel.totalSpins(), spins, "global spins vs history lengths");
        assertEq(spins, successfulSpins);
        assertEq(wheel.totalParticipants(), participants, "distinct successful spinners");
        assertEq(wheel.currentDay(), vm.getBlockTimestamp() / 1 days);
        uint256 next = wheel.nextDayStartsAt();
        assertGt(next, vm.getBlockTimestamp());
        assertLe(next - vm.getBlockTimestamp(), 1 days);
        assertEq(next % 1 days, 0);
        assertEq(address(wheel.badge()), address(badge));
    }

    function _assertLeaderboard() private view {
        WheelSpinCheckIn.LeaderboardEntry[] memory board = wheel.leaderboard();
        assertEq(board.length, wheel.leaderboardLength());
        assertEq(board.length, wheel.totalParticipants());
        assertLe(board.length, wheel.LEADERBOARD_SIZE());
        for (uint256 i; i < board.length; ++i) {
            WheelSpinCheckIn.LeaderboardEntry memory entry = board[i];
            History memory h = _history(entry.account);
            assertGt(h.total, 0, "unknown or unspun account on board");
            assertEq(wheel.rankOf(entry.account), i + 1, "rank index or duplicate entry");
            assertEq(entry.currentStreak, h.current);
            assertEq(entry.longestStreak, h.longest);
            assertEq(entry.totalCheckIns, h.total);
            assertEq(entry.lastSpinDay, h.lastDay);
            if (i != 0) assertGe(board[i - 1].longestStreak, entry.longestStreak, "board must be descending");
        }
    }
}

contract SqueekBoardLifecycleInvariantTest is Test {
    SqueekBoardLifecycleHandler internal handler;

    function setUp() public {
        vm.warp(0); // Also exercises the first-spin sentinel at epoch day zero.
        HamsterBadge badge = new HamsterBadge();
        WheelSpinCheckIn wheel = new WheelSpinCheckIn(address(badge));
        handler = new SqueekBoardLifecycleHandler(badge, wheel);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.setOperator.selector;
        selectors[3] = handler.transfer.selector;
        selectors[4] = handler.spin.selector;
        selectors[5] = handler.spinMany.selector;
        selectors[6] = handler.advanceTime.selector;
        selectors[7] = handler.nextDay.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_badgeAccountingAuthorizationAndSpinHistoryAgree() public view {
        handler.assertState();
    }

    /// @dev Deterministic harness check: exercises success AND rejection paths rather than relying
    /// on random coverage. This also pins a transfer-away / receive-back round trip.
    function test_handlerExercisesGrantsRevocationsTransfersAndSpinRejections() public {
        handler.spin(0);
        handler.spin(0); // duplicate
        handler.spin(11); // no badge
        handler.mint(0); // duplicate mint
        handler.mint(11);
        handler.approve(0, 2, 0, true);
        handler.approve(0, 3, 2, false); // token approval cannot delegate
        handler.transfer(0, 11, 2, 1, true); // approved transfer; actor 11 now has two badges
        handler.transfer(0, 0, 2, 2, false); // old approval cleared
        handler.transfer(0, 0, 11, 0, false); // owner returns token
        handler.spin(0); // returning badge does not unlock a second spin
        handler.setOperator(0, 2, true);
        handler.approve(0, 3, 2, false); // operator can delegate
        handler.setOperator(0, 2, false);
        handler.transfer(0, 11, 2, 2, false); // revoked operator
        handler.nextDay();
        handler.spinMany(0, 12);
        handler.advanceTime(2 days);
        handler.spinMany(0, 12); // lapsed histories restart
        handler.assertState();
        assertEq(handler.successfulMints(), 7);
        assertEq(handler.rejectedMints(), 1);
        assertEq(handler.successfulApprovals(), 2);
        assertEq(handler.rejectedApprovals(), 1);
        assertEq(handler.successfulTransfers(), 2);
        assertEq(handler.rejectedTransfers(), 2);
        assertEq(handler.successfulSpins(), 15);
        assertEq(handler.rejectedSpins(), 13);
    }
}
