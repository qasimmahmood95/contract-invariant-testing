# ADR-0002: Stateful invariant testing + targeted fuzz over example-based unit tests

Status: Accepted
Date: 2026-07-26

## Context

The SUT's guarantees are universally quantified: *no* operation executes
early, under *any* interleaving of schedule/cancel/execute/role calls by
*any* actor at *any* point in time. Example-based tests encode failure modes
the author already imagined; the custody-relevant bugs live in sequences
nobody writes fixtures for (cancel-then-revive timing, delay changes racing
in-flight operations, execution exactly at the readiness boundary). This is
the same argument as reconciliation-testing's ADR-0001, with the input space
extended from data-and-arrival-order to contract-state-and-time.

## Decision

Two complementary layers:

1. **Stateful invariant campaign** (Foundry `invariant_*`): a handler
   contract drives bounded, realistic call sequences — multiple role-holding
   actors plus outsiders, time moving only via bounded `vm.warp` actions —
   while maintaining *ghost state* (expected ready times, lifecycle status,
   role sets, balances) recomputed independently of the SUT. Invariants
   INV-1…INV-8 (docs/PLAN.md §2) compare SUT reality against ghost truth
   after every sequence.
2. **Targeted fuzz tests** (FZ-1…FZ-6) for example-shaped edges the campaign
   asserts only statistically: exact readiness-boundary second, sub-minDelay
   rejection, id collision, predecessor gating, caller×function matrix,
   batch atomicity.

Policies that keep the layers honest:

- `fail_on_revert = true` — a handler action that reverts unexpectedly fails
  the campaign; expected-revert probes go through explicit `try/catch`
  actions with ghost counters, so silent no-op fuzzing cannot go green.
- Every test carries a structured header (property / custody risk /
  falsification lever) and must be shown to fail when its property is broken
  (hard limit 3; harness levers + the single planted defect, M4).

## Consequences

- Handler quality is the load-bearing component; the code-review subagent
  gate explicitly checks for unbounded inputs, tautological assertions, and
  ghost-state drift from SUT semantics.
- Campaign parameters (runs/depth) are budgeted to ≤ ~5 min in CI and pinned
  (ADR-0004), trading exhaustiveness for reproducibility; the planted-defect
  demo proves the chosen budget actually finds the bug class.
