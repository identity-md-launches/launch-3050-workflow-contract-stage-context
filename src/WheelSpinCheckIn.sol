// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title WheelSpinCheckIn
/// @notice Daily "wheel spin" check-in for Hamster Badge holders. A wallet that holds at least one
///         badge may record one spin per UTC day. The contract stores every wallet's current
///         streak, longest streak and total check-ins, and keeps a bounded on-chain leaderboard of
///         the longest streaks.
/// @dev Design notes:
///      - A "day" is a UTC day: `block.timestamp / 1 days`. Spinning on consecutive UTC days grows
///        the streak; missing a whole UTC day resets it to 1 on the next spin.
///      - A spin is a check-in only. It has no random outcome and awards nothing of value, so no
///        randomness source is used.
///      - There is no owner, admin, pause or upgrade path, and the contract never holds ETH or
///        tokens. Its only external call is the read-only `balanceOf` on the immutable badge.
///      - Streaks belong to wallets, not to badges. The holder check is made at spin time.
///      - The leaderboard ranks wallets by their longest (best ever) streak. A longest streak only
///        ever grows, by exactly one per spin, which lets the board be kept sorted with a binary
///        search and a single swap: the gas cost of a spin is bounded regardless of how many
///        wallets take part.
///      - Linter notes. `block.timestamp` is only used at day granularity: a validator can shift it by
///        seconds, which matters only for a spin sent within seconds of midnight UTC and moves
///        nothing of value. The badge balance is compared with zero on purpose: holding any badge
///        qualifies. The matching `forge lint` warnings are silenced where they occur.
contract WheelSpinCheckIn {
    /// @notice Maximum number of wallets on the on-chain leaderboard.
    uint256 public constant LEADERBOARD_SIZE = 100;

    /// @notice Length of one check-in period, in seconds (one UTC day).
    uint256 public constant DAY = 1 days;

    /// @notice The Hamster Badge collection whose holders may spin.
    IERC721 public immutable badge;

    /// @notice Number of distinct wallets that have spun at least once.
    uint256 public totalParticipants;

    /// @notice Number of spins recorded across all wallets.
    uint256 public totalSpins;

    /// @dev Per-wallet record, packed into one storage slot.
    ///      `currentStreak` is the streak as of `lastSpinDay`; the public views report 0 once it lapsed.
    ///      `rank` is the 1-based leaderboard position, or 0 when the wallet is not on the board.
    struct Record {
        uint48 lastSpinDay;
        uint48 currentStreak;
        uint48 longestStreak;
        uint48 totalCheckIns;
        uint16 rank;
    }

    /// @dev One leaderboard position, packed into one storage slot. `streak` mirrors the wallet's
    ///      longest streak so the board can be searched without touching each wallet's record.
    struct Slot {
        address account;
        uint48 streak;
    }

    /// @notice A leaderboard row as returned by `leaderboard`.
    struct LeaderboardEntry {
        address account;
        uint256 longestStreak;
        uint256 currentStreak;
        uint256 totalCheckIns;
        uint256 lastSpinDay;
    }

    mapping(address account => Record) private _records;

    /// @dev Sorted by `streak`, longest first. Never longer than `LEADERBOARD_SIZE`.
    Slot[] private _board;

    /// @notice `account` recorded its spin for UTC day `day`.
    event Spun(
        address indexed account,
        uint256 indexed day,
        uint256 currentStreak,
        uint256 longestStreak,
        uint256 totalCheckIns
    );

    /// @notice The badge address given at deployment was the zero address.
    error ZeroBadgeAddress();

    /// @notice The caller holds no Hamster Badge.
    error NotBadgeHolder(address account);

    /// @notice The caller already recorded its spin for UTC day `day`.
    error AlreadySpunToday(address account, uint256 day);

    /// @param badge_ Address of the Hamster Badge collection. It is not called here, so the two
    ///        contracts can be deployed in any order within one transaction; it is first read on `spin`.
    constructor(address badge_) {
        if (badge_ == address(0)) revert ZeroBadgeAddress();
        badge = IERC721(badge_);
    }

    /// @notice Records the caller's wheel spin for the current UTC day.
    /// @dev Reverts if the caller holds no badge or has already spun today.
    /// @return streak The caller's current streak after this spin.
    function spin() external returns (uint256 streak) {
        address account = msg.sender;
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (badge.balanceOf(account) == 0) revert NotBadgeHolder(account);

        uint48 today = _today();
        Record memory record = _records[account];
        bool firstSpin = record.totalCheckIns == 0;

        // forge-lint: disable-next-line(block-timestamp)
        if (!firstSpin && record.lastSpinDay == today) revert AlreadySpunToday(account, today);

        // The streak continues only if the previous spin was on the UTC day right before this one.
        // forge-lint: disable-next-line(block-timestamp)
        bool continuesStreak = !firstSpin && uint256(record.lastSpinDay) + 1 == today;
        record.currentStreak = continuesStreak ? record.currentStreak + 1 : 1;

        if (firstSpin) totalParticipants += 1;
        record.lastSpinDay = today;
        record.totalCheckIns += 1;
        totalSpins += 1;

        if (record.currentStreak > record.longestStreak) {
            record.longestStreak = record.currentStreak;
            record.rank = _place(account, record.longestStreak, record.rank);
        }

        _records[account] = record;

        emit Spun(account, today, record.currentStreak, record.longestStreak, record.totalCheckIns);
        return record.currentStreak;
    }

    /// @notice The current UTC day number (`block.timestamp / 1 days`).
    function currentDay() external view returns (uint256) {
        return _today();
    }

    /// @notice Timestamp at which the next UTC day, and so the next spin window, starts.
    function nextDayStartsAt() external view returns (uint256) {
        return (uint256(_today()) + 1) * DAY;
    }

    /// @notice `account`'s live streak: consecutive UTC days spun, ending today or yesterday.
    /// @dev Returns 0 once a whole UTC day was missed, even before the wallet spins again.
    function currentStreak(address account) public view returns (uint256) {
        return _liveStreak(_records[account], _today());
    }

    /// @notice The longest streak `account` has ever reached.
    function longestStreak(address account) external view returns (uint256) {
        return _records[account].longestStreak;
    }

    /// @notice Total number of spins `account` has recorded.
    function totalCheckIns(address account) external view returns (uint256) {
        return _records[account].totalCheckIns;
    }

    /// @notice UTC day number of `account`'s latest spin (meaningful only if it has spun).
    function lastSpinDay(address account) external view returns (uint256) {
        return _records[account].lastSpinDay;
    }

    /// @notice Whether `account` already recorded its spin for the current UTC day.
    function hasSpunToday(address account) public view returns (bool) {
        Record storage record = _records[account];
        // forge-lint: disable-next-line(block-timestamp)
        return record.totalCheckIns != 0 && record.lastSpinDay == _today();
    }

    /// @notice Whether a `spin` by `account` would succeed right now.
    function canSpin(address account) external view returns (bool) {
        // forge-lint: disable-next-line(incorrect-strict-equality)
        return !hasSpunToday(account) && badge.balanceOf(account) != 0;
    }

    /// @notice Everything the app shows for one wallet, in a single call.
    /// @return current Live current streak (0 if lapsed or never spun).
    /// @return longest Longest streak ever reached.
    /// @return total Total number of spins.
    /// @return lastDay UTC day number of the latest spin.
    /// @return spunToday Whether today's spin is already recorded.
    /// @return rank 1-based leaderboard position, or 0 if not on the leaderboard.
    function statsOf(address account)
        external
        view
        returns (uint256 current, uint256 longest, uint256 total, uint256 lastDay, bool spunToday, uint256 rank)
    {
        Record memory record = _records[account];
        uint48 today = _today();
        current = _liveStreak(record, today);
        longest = record.longestStreak;
        total = record.totalCheckIns;
        lastDay = record.lastSpinDay;
        // forge-lint: disable-next-line(block-timestamp)
        spunToday = record.totalCheckIns != 0 && record.lastSpinDay == today;
        rank = record.rank;
    }

    /// @notice 1-based leaderboard position of `account`, or 0 if it is not on the leaderboard.
    function rankOf(address account) external view returns (uint256) {
        return _records[account].rank;
    }

    /// @notice Number of wallets currently on the leaderboard (at most `LEADERBOARD_SIZE`).
    function leaderboardLength() external view returns (uint256) {
        return _board.length;
    }

    /// @notice The leaderboard, longest streak first, with each wallet's live stats.
    /// @dev Wallets with equal longest streaks appear in no guaranteed order.
    function leaderboard() external view returns (LeaderboardEntry[] memory entries) {
        uint256 size = _board.length;
        uint48 today = _today();
        entries = new LeaderboardEntry[](size);
        for (uint256 i = 0; i < size; ++i) {
            address account = _board[i].account;
            Record memory record = _records[account];
            entries[i] = LeaderboardEntry({
                account: account,
                longestStreak: record.longestStreak,
                currentStreak: _liveStreak(record, today),
                totalCheckIns: record.totalCheckIns,
                lastSpinDay: record.lastSpinDay
            });
        }
    }

    /// @dev Puts `account`, whose longest streak just grew to `streak`, in its leaderboard position.
    ///      `rank` is its 1-based position before the call (0 if absent). Returns the new position,
    ///      or 0 if the wallet does not make the board.
    ///
    ///      Why one swap is enough: a longest streak grows by exactly one, so every entry the wallet
    ///      overtakes holds exactly `streak - 1`. Swapping the wallet with the first of those entries
    ///      keeps the board sorted. A wallet outside a full board always has a longest streak no
    ///      greater than the last entry's, so the same holds when it replaces the last entry.
    function _place(address account, uint48 streak, uint16 rank) private returns (uint16) {
        uint256 size = _board.length;
        uint256 index;

        if (rank != 0) {
            index = rank - 1;
        } else if (size < LEADERBOARD_SIZE) {
            index = size;
            _board.push();
        } else {
            index = size - 1;
            Slot memory last = _board[index];
            if (streak <= last.streak) return 0;
            _records[last.account].rank = 0;
        }

        // First position in [0, index) whose streak is below the new one, or `index` if there is none.
        uint256 low = 0;
        uint256 high = index;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (_board[mid].streak < streak) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        if (low != index) {
            Slot memory overtaken = _board[low];
            _board[index] = overtaken;
            _records[overtaken.account].rank = SafeCast.toUint16(index + 1);
        }
        _board[low] = Slot({account: account, streak: streak});
        return SafeCast.toUint16(low + 1);
    }

    function _today() private view returns (uint48) {
        return SafeCast.toUint48(block.timestamp / DAY);
    }

    /// @dev A streak is live while its latest spin was today or yesterday.
    function _liveStreak(Record memory record, uint48 today) private pure returns (uint256) {
        if (record.totalCheckIns == 0) return 0;
        if (uint256(today) > uint256(record.lastSpinDay) + 1) return 0;
        return record.currentStreak;
    }
}
