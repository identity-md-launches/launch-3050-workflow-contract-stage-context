# SqueekBoard contracts

On-chain part of SqueekBoard, the community companion app for Squeekchain, the hamster-powered
testnet on Sepolia. Two contracts, no fungible token:

| Contract | File | What it does |
| --- | --- | --- |
| `HamsterBadge` | `src/HamsterBadge.sol` | ERC-721 collection "Hamster Badge" (`HBADGE`), capped at 10,000, one free mint per wallet. |
| `WheelSpinCheckIn` | `src/WheelSpinCheckIn.sol` | Badge holders record one "wheel spin" per UTC day; stores each wallet's streaks and total check-ins and keeps a leaderboard of the longest streaks. |

ABIs for the web app are in `docs/abi/HamsterBadge.json` and `docs/abi/WheelSpinCheckIn.json`.

Neither contract has an owner, an admin, a pause switch or an upgrade path, and neither can hold
ETH. Once deployed, nobody (the requester and the launch service included) can change their rules.

## HamsterBadge

- Name `Hamster Badge`, symbol `HBADGE`, standard ERC-721 (OpenZeppelin v5.4.0), transferable.
- `mint()` gives the caller one badge. It is free (not payable; the caller pays gas only).
- One mint per wallet, ever: `hasMinted(wallet)` stays true even if the badge is later transferred
  away. Receiving a badge by transfer does not use up a wallet's own free mint.
- Hard cap `MAX_SUPPLY = 10,000`. Token ids run from 1 to 10,000 in mint order. There is no owner
  mint, no reserve and no burn, so `totalSupply()` only goes up and stops at the cap.
- `tokenURI(id)` returns self-contained metadata (`data:application/json;base64,...`) with an SVG
  image generated on-chain. Nothing is hosted, so there is no base URI to set or to break.
- Helpers for the app: `totalSupply()`, `remainingSupply()`, `canMint(wallet)`, `hasMinted(wallet)`.

| Call | Fails with | When |
| --- | --- | --- |
| `mint()` | `AlreadyMinted(account)` | the caller already minted |
| `mint()` | `MaxSupplyReached()` | all 10,000 badges exist |
| `tokenURI(id)`, `ownerOf(id)` | `ERC721NonexistentToken(id)` | the id was never minted |

## WheelSpinCheckIn

- `spin()` records the caller's check-in for the current UTC day and returns the caller's streak.
  The caller must hold at least one Hamster Badge at that moment.
- A day is a UTC day: `block.timestamp / 86400`. One spin per wallet per UTC day; the next window
  opens at 00:00 UTC (`nextDayStartsAt()`).
- Streak rules: spinning on the UTC day right after the previous spin adds 1 to the streak. Missing
  a whole UTC day resets the streak, and the next spin starts again at 1. Longest streak and total
  check-ins are never reduced.
- A spin is a check-in only: it has no random outcome and awards nothing, so no randomness source
  is involved.
- Stored per wallet: current streak, longest streak, total check-ins, day of the last spin.

Reads for the app:

| Function | Returns |
| --- | --- |
| `statsOf(wallet)` | live current streak, longest streak, total check-ins, last spin day, whether today's spin is done, leaderboard rank (0 = not ranked) |
| `currentStreak(wallet)` | live streak: 0 as soon as a whole UTC day was missed, even before the next spin |
| `longestStreak(wallet)`, `totalCheckIns(wallet)`, `lastSpinDay(wallet)` | the stored values |
| `hasSpunToday(wallet)`, `canSpin(wallet)` | whether today's spin is recorded / whether `spin()` would succeed now |
| `leaderboard()` | up to 100 rows `(account, longestStreak, currentStreak, totalCheckIns, lastSpinDay)`, longest streak first |
| `leaderboardLength()`, `rankOf(wallet)` | board size, 1-based rank (0 = not ranked) |
| `totalParticipants()`, `totalSpins()` | global counters |
| `currentDay()`, `nextDayStartsAt()` | current UTC day number, timestamp of the next UTC midnight |

Event for indexers: `Spun(account indexed, day indexed, currentStreak, longestStreak, totalCheckIns)`.

| Call | Fails with | When |
| --- | --- | --- |
| `spin()` | `NotBadgeHolder(account)` | the caller holds no badge |
| `spin()` | `AlreadySpunToday(account, day)` | the caller already spun this UTC day |
| constructor | `ZeroBadgeAddress()` | the badge address argument is zero |

### The leaderboard

The board is kept on-chain so the web app can show it with one read and no indexer.

- It ranks wallets by their **longest (best ever) streak**, and each row also carries the wallet's
  live current streak, so the app can show either figure.
- It holds at most `LEADERBOARD_SIZE = 100` wallets. A wallet outside a full board enters only when
  its longest streak is strictly greater than the last row's, which then drops off. A wallet that
  drops off keeps its own record and can come back with a longer streak.
- Wallets with equal longest streaks appear in no guaranteed order. The app may break ties as it
  likes (for example by total check-ins).
- A longest streak only grows, one step per spin, so the board is kept sorted with a binary search
  and a single swap. A spin costs a bounded amount of gas (under 150,000 in the worst case tested)
  however many wallets take part, and a crowd of throwaway wallets with 1-day streaks cannot push
  real streaks off the board.

## Chosen values

The brief left these open. They are named constants and cannot be changed after deployment.

| Constant | Value | Why |
| --- | --- | --- |
| `HamsterBadge.MAX_SUPPLY` | 10,000 | from the brief |
| `WheelSpinCheckIn.DAY` | 86,400 seconds, aligned to UTC midnight | "daily" read as calendar days, the same for every visitor |
| `WheelSpinCheckIn.LEADERBOARD_SIZE` | 100 | enough for a public leaderboard page while keeping a spin cheap |
| First token id | 1 | conventional |

## Assumptions and design decisions

1. **Badges are transferable.** The brief asks for an ERC-721 collection and does not ask for a
   soulbound token. "One per wallet" is enforced on minting, not on holding: a wallet can hold
   several badges it received by transfer.
2. **Streaks belong to wallets, not badges.** The brief stores "each wallet's current streak and
   total check-ins". The holder check happens at spin time: a wallet that gives its badge away
   keeps its history but cannot spin until it holds a badge again. One badge passed between wallets
   lets each of them spin on the same day. That gains nothing a free mint does not already give,
   and a streak of N still takes N daily transactions over N days from the same wallet.
3. **One wallet is not one person.** Anyone can use many wallets to mint many badges until the cap
   is reached. This is inherent to a free, permissionless mint; the brief asks for a per-wallet
   limit and that is what is enforced.
4. **`mint()` uses `_mint`, not `_safeMint`.** The badge always goes to the caller, who asked for
   it. Skipping the receiver callback means minting makes no external call at all (no reentrancy
   surface) and smart accounts without an `onERC721Received` hook can mint too.
5. **Day boundaries use the block timestamp.** A validator can shift a block's timestamp by a few
   seconds, which only matters for a spin sent within seconds of midnight UTC. Nothing of value
   depends on it.
6. **Metadata is on-chain and fixed.** The artwork is a simple SVG stored in the contract. It
   cannot be replaced later; that is the price of having no admin and no hosting dependency.
7. **"Leaderboard of the longest streaks"** is read as a ranking by each wallet's best streak.
   A ranking by current streak cannot be kept on-chain, because a streak lapses with the passing
   of time rather than with a transaction; the live current streak is returned in every row.

## Deployment parameters

Chain: Sepolia (chain id 11155111). The launch deploys both contracts from their built bytecode;
this repository contains no `launch.json` (the manifest step writes it).

| Order | Contract | Constructor arguments |
| --- | --- | --- |
| 1 | `HamsterBadge` | none |
| 2 | `WheelSpinCheckIn` | `badge_` (address): the deployed `HamsterBadge`, i.e. `$contract:HamsterBadge` |

- No owner argument exists on either contract, so `$owner` is not used: there is nothing to own.
  The launch owner's wallet is an ordinary user of both contracts.
- Both constructors are non-payable, take only static arguments, and call no other contract.
  `WheelSpinCheckIn` only stores the badge address and first reads it when someone spins, so the
  constructors run on an empty chain. A zero badge address is refused.
- The check-in contract's badge address is immutable. If it were given a wrong address the fix is
  to redeploy `WheelSpinCheckIn`; the badge collection is unaffected.
- Build settings (`foundry.toml`): solc 0.8.26, EVM version cancun, optimizer on (200 runs),
  `bytecode_hash = "none"`. No libraries need linking.
- Runtime sizes: `HamsterBadge` about 6.7 KB, `WheelSpinCheckIn` about 4.2 KB (limit 24,576 bytes).

## After launch

Nothing has to be set. Neither contract has a setter, and both work from the first block.

## Operational responsibilities

- **Requester / owner (`0xcc2005844aeabbd4d663f7c45c9bd1369eb062b3`)**: no on-chain duties and no
  on-chain powers. There is no key to guard for these contracts and nothing to hand over.
- **Web app**: point it at the two deployed addresses from the deployment handoff (never invented
  addresses) and at Sepolia. Suggested calls: `HamsterBadge.canMint` / `mint`, then
  `WheelSpinCheckIn.statsOf`, `canSpin`, `spin`, `leaderboard`. Show times in UTC or count down to
  `nextDayStartsAt()`, since the day changes at 00:00 UTC for everyone. Treat `currentStreak` from
  `statsOf`/`leaderboard` as the live value.
- **Users**: pay their own gas. A missed UTC day cannot be made up, and nobody can restore a streak.
- **Nobody can**: mint more than 10,000 badges, mint a second badge for a wallet, edit a streak,
  remove a wallet from the leaderboard, pause either contract, or upgrade it.
- **Independent security review**: requested in the brief. It is a separate step by another
  contributor, after this work; the tests here are not an audit.

## Security notes

- No ETH or ERC-20 custody; no payable function; no `delegatecall`, `selfdestruct` or proxy.
- `HamsterBadge.mint` makes no external call. `WheelSpinCheckIn.spin` makes one read-only call
  (`balanceOf`) to the immutable badge contract before it changes any state.
- No loops over user-controlled, unbounded data in state-changing code: the leaderboard update is a
  binary search over at most 100 slots plus one swap.
- Per-wallet counters are 48-bit and grow by at most one per day; arithmetic is checked.
- `forge lint` warnings that were reviewed and accepted are silenced in place with a reason
  (timestamp use at day granularity, comparing the badge balance with zero, `_mint` to the caller).
- Tools run for this work: `forge build`, `forge test` (unit, fuzz and invariant tests),
  `forge fmt --check`, `forge lint`. Slither and Mythril were not available here.

## Tests

```
forge build
forge test
forge fmt --check
```

| File | Covers |
| --- | --- |
| `test/HamsterBadge.t.sol` | name, symbol, free mint, one per wallet (also after transferring away), the 10,000 cap at its boundary, no ETH accepted, no admin surface, transfers, on-chain metadata |
| `test/Base64Encoder.t.sol` | RFC 4648 vectors and a fuzz comparison against a reference encoder |
| `test/WheelSpinCheckIn.t.sol` | holder gating, one spin per UTC day, midnight boundary, streak growth and reset, live streak view, badge transfers, fuzzed schedules against a reference model |
| `test/WheelSpinLeaderboard.t.sol` | ranking, overtaking, the 100-wallet cap and eviction, flooding with 1-day wallets, bounded gas, a multi-day fuzz test and a stateful invariant test (random spins, time jumps and badge transfers checked against a reference model) |
| `test/LaunchRehearsal.t.sol` | CREATE2 deployment by a factory stand-in in one call, wiring, no owner, runtime size and forbidden-opcode scan, the local deploy script |

The tests read no environment variables and pass in any order.

## Layout and dependencies

```
src/HamsterBadge.sol            ERC-721 badge
src/WheelSpinCheckIn.sol        daily check-in, streaks, leaderboard
src/libraries/Base64Encoder.sol Base64 for the on-chain metadata (internal functions only)
script/Deploy.s.sol             local/dev deployment helper (the launch does not use it)
docs/abi/                       ABI exports
lib/forge-std                   forge-std v1.9.7 (vendored, test only)
lib/openzeppelin-contracts      OpenZeppelin Contracts v5.4.0 (vendored; only the files this project compiles)
```

Dependencies are committed as ordinary files (no git submodules), so the project builds offline.
To refresh the ABI exports after a change: `forge inspect HamsterBadge abi --json > docs/abi/HamsterBadge.json`
and the same for `WheelSpinCheckIn`.
