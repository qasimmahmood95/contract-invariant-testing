# contract-invariant-testing

[![ci](https://github.com/qasimmahmood95/contract-invariant-testing/actions/workflows/ci.yml/badge.svg)](https://github.com/qasimmahmood95/contract-invariant-testing/actions/workflows/ci.yml)

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

**Status: M4 (planted defect + falsification).** INV-1…INV-8 run against a
ghost-accounting handler; FZ-1…FZ-6 pin the example-shaped edges; CI reports
SUT path coverage filtered to `TimelockController.sol`. `npm run falsify`
proves every property can fail: all 14 `FALSIFY=<id>` harness levers plus the
planted defect (`test/defect/EagerTimelockController.sol`, a 15-minute "ops
grace window" subclass) go red, and the defect's committed counterexample —
a 3-call `schedule → warp → execute` sequence — replays byte-for-byte.
Release polish (headline links, reproduce-from-clean-clone walkthrough) lands
in M5. The full milestone plan and the invariant → custody-risk table are in
[docs/PLAN.md](docs/PLAN.md).

## Why a timelock

A `TimelockController` has one job: nothing the keys authorize takes effect
until a mandatory reaction window has passed, during which a separate role
can veto it. Every invariant in this suite is a facet of that promise — delay
integrity, cancellation finality, role segregation, no double execution,
self-administered configuration. Why this target over a Safe core (including
the decisive `virtual`-hook evidence) is
[ADR-0001](docs/adr/0001-target-selection.md); why invariants over example
tests is [ADR-0002](docs/adr/0002-invariant-and-fuzz-testing-over-example-tests.md).

## Reproducibility

Everything is pinned (ADR-0004): forge `v1.7.1`, solc `0.8.28`, OpenZeppelin
`v5.6.1` (submodule at the tag commit), fuzz seed `0x20260726` in
`foundry.toml`. CI is hermetic — no RPC, no forking
([ADR-0003](docs/adr/0003-local-deploy-over-pinned-fork.md)).

```bash
git clone --recurse-submodules https://github.com/qasimmahmood95/contract-invariant-testing
cd contract-invariant-testing
forge test
```

## Layout

```
test/           smoke test (M1); handlers, invariants, fuzz suites (M2+)
test/defect/    the single deliberately buggy SUT variant (M4) — clearly bannered
docs/adr/       architecture decision records
docs/PLAN.md    milestone plan and invariant → custody-risk table
lib/            pinned submodules: openzeppelin-contracts v5.6.1, forge-std v1.9.7
```
