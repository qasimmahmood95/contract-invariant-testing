# contract-invariant-testing

Stateful invariant and fuzz test suite (**Foundry**) for **OpenZeppelin
`TimelockController` v5.6.1**, treated strictly as an external, audited
system-under-test. The thesis: on-chain invariant testing *is* property-based
testing — the direct sibling of
[reconciliation-testing](https://github.com/qasimmahmood95/reconciliation-testing)
(fast-check properties over a ledger) with the same discipline applied to a
custody-critical smart contract: state the properties a custodian depends on,
let a seeded fuzzer drive adversarial call sequences, and prove the suite can
fail by planting one deliberate defect and showing the shrunk counterexample.

This is QA methodology on an existing contract. It is not contract
development, not exploit tooling, and not a security audit for hire.

## Hard limits (non-negotiable)

1. **Test code only.** This repo contains test contracts, invariant handlers,
   mock fixtures, docs, and CI. The single exception is **exactly one**
   deliberately buggy SUT variant used for the defect demo:
   `test/defect/EagerTimelockController.sol`, a ~10-line subclass overriding a
   `virtual` hook, carrying a `DELIBERATELY DEFECTIVE — TEST FIXTURE ONLY`
   banner. No other production Solidity, ever.
2. **Never vendor, patch, or fork-edit the SUT.** OpenZeppelin contracts enter
   only as a git submodule pinned to the `v5.6.1` tag commit. If the SUT
   lacked a property worth asserting, that is a documented finding, not a
   patch.
3. **No vacuous passes.** Every invariant and fuzz test must have a documented
   *falsification lever* and must be shown to fail when its property is
   deliberately broken — via the planted defect (INV-1) or via harness-side
   `FALSIFY=<id>` sabotage of the ghost accounting (all others). A test that
   cannot fail must not merge.
4. **Hermetic CI.** No network access beyond `git checkout` + submodules. No
   RPC endpoints, no mainnet forking, no live-chain dependency of any kind.
   The SUT deploys locally in `setUp()` from the pinned source.

## System-under-test facts (verified against v5.6.1 source, 2026-07-26)

- `pragma solidity ^0.8.20`; compiles cleanly alongside 0.8.x test code — no
  solc-fidelity caveat (unlike Safe v1.4.1, whose official builds are 0.7.6).
- Operation state machine: `Unset → Waiting → Ready → Done`, encoded in one
  `_timestamps[id]` slot with sentinels `0` = Unset, `1` = Done
  (`DONE_TIMESTAMP`; renamed from `_DONE_TIMESTAMP` in v5.6.0).
- `getTimestamp(bytes32)` and `getOperationState(bytes32)` are
  `public view virtual` — the designed extension hooks the planted defect
  overrides. `isOperationReady`/`isOperation*` all route through
  `getOperationState`, so an override poisons the readiness check exactly the
  way a real subclass bug would.
- Readiness boundary: `timestamp > block.timestamp` ⇒ Waiting, so execution at
  **exactly** `readyAt` is legal. The boundary fuzz test pins this.
- Constructor wiring: the timelock grants `DEFAULT_ADMIN_ROLE` to **itself**;
  proposers receive both `PROPOSER_ROLE` and `CANCELLER_ROLE`; the optional
  external `admin` is disabled by passing `address(0)` — **our deployment
  config**, making the instance fully self-administered. Granting
  `EXECUTOR_ROLE` to `address(0)` opens execution to everyone
  (`onlyRoleOrOpenRole`) — we do **not** use the open-role config in the core
  suite.
- `updateDelay` is `public virtual` but reverts unless `msg.sender` is the
  timelock itself ⇒ `minDelay` can only change via a scheduled, delayed,
  executed operation.
- `_schedule` rejects any id where `isOperation(id)` is true ⇒ a **Done id can
  never be re-scheduled or re-executed** (no double settlement); reviving a
  cancelled id restarts the full delay.
- Batch operations (`scheduleBatch`/`executeBatch`) hash all calls into one
  id; a revert in any inner call reverts the whole execution atomically.

## Conventions

- **Foundry** (`forge`, `foundry.toml`); Solidity for all test and handler
  contracts. Pin exact solc in `foundry.toml` and exact forge release in CI
  (`foundry-toolchain` with a version tag, never `nightly`); record both in
  the README reproducibility section.
- **Determinism policy.**
  - Fuzz/invariant seed pinned in `foundry.toml` (`seed = "0x20260726"`,
    date-stamped like `FC_SEED=20260718` in reconciliation-testing).
  - `[fuzz] runs`, `[invariant] runs`/`depth`/`shrink_run_limit` pinned;
    CI budget ≤ ~5 minutes for the whole suite.
  - `[invariant] fail_on_revert = true`. Expected-revert probes go through
    explicit `try/catch` handler actions with ghost counters — silent no-op
    fuzzing cannot produce green.
  - All handler inputs bounded with named constants; generators written for
    shrink quality (small action space, legible arguments).
  - Failure corpus (`failure_persist`) committed for the defect demo so the
    counterexample replays byte-for-byte from a clean clone.
  - No wall-clock, no unseeded randomness anywhere in test code; time moves
    only via bounded `vm.warp` handler actions.
- **Test documentation.** Every invariant/fuzz test carries a structured
  header comment: (1) the property, (2) the custody risk it maps to, (3) the
  falsification lever. IDs (`INV-x`, `FZ-x`) trace to the table in
  [docs/PLAN.md](docs/PLAN.md).
- **Conventional commits** (`feat:`, `test:`, `docs:`, `ci:`, `chore:`).
- **ADRs** in `docs/adr/NNNN-*.md`. Required minimum: 0001 target selection
  (TimelockController over Safe/Governor, with the `virtual`-hook evidence),
  0002 invariant + fuzz testing over example-based unit tests, 0003 local
  deploy over pinned fork, 0004 determinism and reproducibility.
- **gitleaks** as pre-commit hook (`.githooks/`) and as a required CI job.

## Commands (once scaffolded — M1)

```bash
forge build                          # compile SUT (pinned submodule) + suite
forge test                           # full fuzz + invariant suite, green on main
forge test --match-path 'test/invariant/*'   # invariant campaign only
forge coverage --report lcov         # coverage (filtered report in CI summary)
npm run falsify                      # falsification harness (M4): proves every
                                     # invariant can fail; defect variant must go red
```

## Subagent protocol

- **Code-review subagent** before every milestone PR: reviews the diff for
  weak or tautological assertions, unbounded handler inputs, determinism
  violations, ghost-state drift from SUT semantics, and scope violations
  (any OZ source modification = automatic block).
- **Verification subagent** before every milestone PR, from a **clean clone**:
  `forge build` + full suite green at pinned versions; from M4 on, also runs
  the falsification harness and confirms the planted defect makes INV-1 fail
  with a minimal shrunk call sequence, reproducing identically across two
  consecutive runs. An invariant that passes its falsification run blocks the
  PR.

## CI

GitHub Actions, fully hermetic: checkout with submodules, pinned Foundry
toolchain. Jobs: `build` (`forge build --sizes`), `test` (fuzz + invariant
suite, pinned seed), `coverage` (lcov artifact + filtered summary), `gitleaks`,
and from M4 `falsify` (runs the defect-variant suite, asserts it exits
non-zero, and publishes the shrunk counterexample sequence in the job summary
and as an artifact). The `defect/eager-execution` branch runs the standard
suite against the defective variant and is **red by design** — the linked
failing run is the repo's headline artifact.

## Merge protocol

Milestone PRs are one per milestone, merged with a merge commit (never squash
— the conventional-commit history is part of the portfolio). Self-merge is
**not yet authorized for this repo**: the owner (qasimmahmood95) merges after
review, unless the standing "check and merge yourself" instruction recorded in
resilience-testing (2026-07-18) is explicitly extended here. If extended, the
conditions carry over unchanged: both subagent gates passed, CI green on the
head commit, no unresolved review comments.
