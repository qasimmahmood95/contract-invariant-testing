# contract-invariant-testing

[![ci](https://github.com/qasimmahmood95/contract-invariant-testing/actions/workflows/ci.yml/badge.svg)](https://github.com/qasimmahmood95/contract-invariant-testing/actions/workflows/ci.yml)
[![defect branch — red by design](https://github.com/qasimmahmood95/contract-invariant-testing/actions/workflows/ci.yml/badge.svg?branch=defect%2Feager-execution)](https://github.com/qasimmahmood95/contract-invariant-testing/actions/workflows/ci.yml?query=branch%3Adefect%2Feager-execution)

Stateful invariant and fuzz testing of OpenZeppelin's
[`TimelockController`](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.6.1/contracts/governance/TimelockController.sol)
(pinned at `v5.6.1`) with Foundry. The thesis: on-chain invariant testing *is*
property-based testing — the direct sibling of
[reconciliation-testing](https://github.com/qasimmahmood95/reconciliation-testing),
which fuzzed *data and arrival order* against a ledger; this repo fuzzes
*contract state and time* against the enforced-delay primitive institutional
custody depends on. Same discipline in both: state the invariant a custodian
relies on, let a seeded generator search adversarial sequences for
violations, and prove the suite can fail by planting one deliberate defect
and publishing the shrunk minimal counterexample.

This is QA methodology applied to an existing, audited contract — written as
test harnesses only. It is not contract development, not exploit tooling,
and not a security audit.

## The headline artifact

`test/defect/EagerTimelockController.sol` is a deliberately defective,
clearly bannered subclass: it overrides the one `public view virtual` hook
every readiness check routes through, giving executors a quiet 15-minute
"ops grace window" before the delay a proposer paid for has elapsed.
Sentinels intact, role checks intact — the kind of subclass bug example-based
tests miss.

The seeded invariant campaign catches it and shrinks the violation to
**three calls**:

```text
schedule(op)            # any operation — the fuzzer picked a delay update
warpToBoundary(...)     # land inside [readyAt − 15 min, readyAt)
executeOp(...)          # succeeds 333 s early ⇒ INV-1 red
```

- The [`defect/eager-execution` branch](https://github.com/qasimmahmood95/contract-invariant-testing/tree/defect/eager-execution)
  points the standard suite at the variant — its
  [CI runs are red by design](https://github.com/qasimmahmood95/contract-invariant-testing/actions/workflows/ci.yml?query=branch%3Adefect%2Feager-execution)
  ([the failing run](https://github.com/qasimmahmood95/contract-invariant-testing/actions/runs/30198185859)).
- On `main`, the `falsify` CI job re-derives the failure on every push and
  publishes the shrunk sequence in its job summary; the committed corpus
  (`test/failures/`) replays it byte-for-byte from a clean clone.

## Reproduce it yourself (three commands)

```bash
git clone --recurse-submodules https://github.com/qasimmahmood95/contract-invariant-testing
cd contract-invariant-testing
SUT=eager forge test --match-test invariant_INV1_delayIntegrity   # red, 3-call replay
```

And prove the *whole suite* can fail — every property red under its own
sabotage lever, none vacuously green:

```bash
npm run falsify   # 14 FALSIFY levers + the planted defect: 15/15 must go red
```

## What is asserted

A `TimelockController` has one job: nothing the keys authorize takes effect
until a mandatory reaction window has passed, during which a separate role
can veto it. Every invariant is a facet of that promise, checked after every
fuzzed call against handler-side ghost truth (never SUT-derived values):

| ID | Invariant | Custody risk if it breaks |
|----|-----------|---------------------------|
| INV-1 | delay-integrity: nothing executes before its ghost `readyAt`; the boundary second itself is legal | zero-notice withdrawal — **target of the planted defect** |
| INV-2 | min-delay-floor: every accepted schedule respected the floor in force | veto window silently below policy |
| INV-3 | cancel-is-final: cancelled ⇒ Unset, never lands; revival restarts the full delay | a vetoed withdrawal executing anyway |
| INV-4 | role-segregation: every unauthorized schedule/cancel/execute probe rejected | rogue single-key actor |
| INV-5 | state-machine: ghost lifecycle ⇔ SUT state, Done terminal (no re-schedule/re-execute) | on-chain double settlement |
| INV-6 | self-administered-delay: `minDelay` moves only via an executed operation | shrink-the-window attack precursor |
| INV-7 | self-administered-roles: membership moves only via executed operations | backdoor signer without delay or quorum |
| INV-8 | value-conservation: treasury balance = funding − executed outflow, closed system | unauthorized settlement |

Targeted fuzz tests FZ-1…FZ-6 pin the example-shaped edges: the exact
readiness second (FZ-1), exact revert selectors and argument order
(FZ-2/FZ-3), predecessor gating at any warp (FZ-4), the full caller × action
matrix (FZ-5), and batch atomicity — one failing leg reverts everything,
zero partial effects (FZ-6). Full property → custody-risk mapping in
[docs/PLAN.md](docs/PLAN.md).

**No vacuous passes:** every invariant and fuzz test carries a
`FALSIFY=<id>` lever that sabotages precisely its own ghost accounting or
expectation; `npm run falsify` requires all of them red. A deterministic
wiring test additionally proves every handler action and revert probe live —
the campaign cannot pass by silently doing nothing (`fail_on_revert = true`
plus try/catch probe counters).

## Reproducibility

Everything is pinned (ADR-0004): forge `v1.7.1`, solc `0.8.28`, OpenZeppelin
`v5.6.1` and forge-std `v1.9.7` (submodules at tag commits, recorded in
`foundry.lock`), fuzz seed `0x20260726`, runs/depth/`shrink_run_limit` in
`foundry.toml`. CI is hermetic — no RPC, no forking, SHA-pinned actions
([ADR-0003](docs/adr/0003-local-deploy-over-pinned-fork.md)). The CI
`determinism` job runs the campaign twice per push and diffs a
sequence-sensitive fingerprint; the `coverage` job reports SUT path coverage
filtered to `TimelockController.sol` (93% lines at the pinned config — no
vanity all-libs totals).

Determinism is guaranteed per pinned (forge, solc, config) triple; a
different forge release may legally produce different sequences.

## Why this target

Why `TimelockController` over a Safe core or Governor — including the
decisive evidence that Safe v1.4.1/v1.5.0 expose no `virtual` hook for a
planted-defect subclass, while the timelock is built for inheritance — is
[ADR-0001](docs/adr/0001-target-selection.md). Why invariants + fuzz over
example-based tests is
[ADR-0002](docs/adr/0002-invariant-and-fuzz-testing-over-example-tests.md).
Honest findings are recorded in docs/PLAN.md §3 implementation notes: the
defect also trips INV-5 (the state machine sees the same lie), and FZ-1
would independently catch this defect class at the exact boundary — defense
in depth, stated rather than staged.

## Layout

```
test/Deploy.t.sol        hermetic deploy + lifecycle smoke test
test/invariant/          INV-1…INV-8 campaign, ghost-accounting handler, wiring proof
test/fuzz/               FZ-1…FZ-6 targeted fuzz suite
test/mocks/              MockTarget — SUT-independent execution log
test/defect/             EagerTimelockController — the single bannered defect variant
test/failures/           committed counterexample corpus (byte-for-byte replay)
scripts/falsify.sh       falsification harness (npm run falsify)
docs/PLAN.md             milestone plan, invariant tables, M4 implementation notes
docs/adr/                architecture decision records 0001–0004
lib/                     pinned submodules: openzeppelin-contracts v5.6.1, forge-std v1.9.7
```

## Commands

```bash
forge build                                  # compile SUT (pinned submodule) + suite
forge test                                   # full suite — 17 tests, green on main
forge test --match-path 'test/invariant/*'   # invariant campaign only
forge coverage --include-libs --report summary   # SUT path coverage
npm run falsify                              # prove every property can fail
```
