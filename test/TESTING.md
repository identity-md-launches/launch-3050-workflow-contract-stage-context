# Additional adversarial tests

These tests supplement the accepted suite without changing application code, dependencies,
configuration, ABI exports, or deployment artifacts. All dependencies were already vendored.
No RPC, fork, environment mutation, FFI, or network access is required.

## Property selection

The five discovery passes from the supplied Pashov reference were applied locally, with the
Trail of Bits reference used to check input generation, non-vacuity, and independence of oracles.
The applicable guarantees come from the approved badge/check-in requirements and the accepted
contracts' public behavior. ERC-20-specific templates were not applied to this ERC-721.

| Discovery pass | Property and source basis | Coverage |
| --- | --- | --- |
| Conservation | Every successful mint creates exactly one existing badge; the sum of all balances equals supply; supply never exceeds 10,000. `HamsterBadge.sol:21–29,45–67`. | Lifecycle ownership log and balance sum; real minting of all 10,000 tokens. |
| State transitions | Mint rights survive transfers; approvals are scoped to owners and cleared on transfer; failed operations leave records unchanged. `HamsterBadge.sol:27–29,45–57` and inherited ERC-721 authorization. | Random mint/approve/revoke/transfer sequences; deterministic unauthorized, incorrect-owner, and receiver-rejection cases. |
| Round trips and boundaries | Transferring away and receiving back cannot restore a mint or daily spin; metadata is unchanged by transfer; UTC midnight controls expiry. `HamsterBadge.sol:65–84`; `WheelSpinCheckIn.sol:109–119,142–150`. | Repeated transfer round trips; metadata before/after callback transfer; timestamp-zero, exact-midnight and uint48-day edge cases. |
| Adversarial interactions | An operator is not a badge holder; a second badge is not a second daily allowance; rejecting a callback rolls back nested minting and check-ins; dependency failures cannot create participation. `WheelSpinCheckIn.sol:104–134`. | Token-approved and operator callers, multiple balances, callback execution in one transaction, reverting/malformed/state-writing balance providers. |
| Protocol-specific structure | Badge ownership/approvals agree with the operation log; spin history is wallet-specific; leaderboard rows are unique, sorted, and agree with history and rank. `WheelSpinCheckIn.sol:147–243,246–305`. | Lifecycle history oracle and cross-contract invariant. Existing 140-actor invariant and 130-wallet tests cover full-board eviction and re-entry. |

## New files

- `HamsterBadgeAdversarial.t.sol`: authorization failures and revocations, self-transfer,
  nonexistent and zero-address inputs, receiver callback arguments and rejection rollback,
  metadata stability, and all 10,000 actual mints. The cap test does not edit storage to fake supply.
- `WheelSpinAdversarial.t.sol`: membership and daily-limit failures, multi-badge wallets,
  repeated transfers, receiver callbacks across both contracts, dependency failures, live streak
  expiry, and checked day narrowing. The uint48 boundary is an arithmetic test, not a prediction
  about practical chain lifetime.
- `invariant/SqueekBoardLifecycle.t.sol`: 256 runs of 64 random handler calls, with unexpected
  reverts treated as failures. Twelve actors can mint, accumulate several badges, grant/revoke
  approvals, transfer safely or normally, spin individually or in groups, and advance time.

The lifecycle handler tracks owners, token approvals, operator permissions, and permanently used
mint rights independently of contract getters. It records successful spin days and reconstructs
contiguous intervals for current/longest streaks, instead of copying the implementation's packed
incremental counters. Expected reverts are checked exactly and do not update the ghost state.
Every invariant check compares the complete actor set, balances, approvals, history, counters,
eligibility views, and leaderboard. A deterministic harness test asserts exact successful and
rejected operation counts so failure branches are known to execute.

The small actor set exercises the interaction of ownership and check-ins efficiently; the existing
large-board tests exercise the 100-entry limit. Neither ordering of tied leaderboard entries nor
one-badge-per-person is assumed. Streaks belong to wallets, and one wallet may hold multiple badges.
Callback tests perform nested actions in the real receiver hook, preserving transaction atomicity.

## Reproduction

Run from the repository root with the assignment's deterministic fuzz seed:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache FOUNDRY_FUZZ_SEED=0xc38ec0f3d387d06101754036d7c63a0c296d726c0269ab09fbaac68df1ba26a1 forge test
```

Build outputs are directed into disposable scratch space to keep this contribution inside its
write scope. Tests do not import or depend on anything in scratch. Ordinary `forge build` and
`forge test` also work with the repository's existing configuration.
