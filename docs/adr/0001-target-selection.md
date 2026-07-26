# ADR-0001: OpenZeppelin TimelockController v5.6.1 as the system-under-test

Status: Accepted (owner sign-off 2026-07-26)
Date: 2026-07-26

## Context

The repo needs one existing, well-known, audited, custody-relevant contract
to invariant-test. Candidates: a Safe (multisig) core, OpenZeppelin
`Governor`, OpenZeppelin `TimelockController`. Hard limits apply: test code
only, at most one clearly-marked deliberately buggy variant, and the SUT is
never vendored, patched, or fork-edited. The planted-defect methodology
(sibling repo: reconciliation-testing) requires that the buggy variant be a
small subclass that weakens exactly one check.

## Decision

Target **`TimelockController` at tag `v5.6.1`** (git submodule pinned to the
tag commit), deployed self-administered: `admin = address(0)`, two proposers
(who per constructor also hold `CANCELLER_ROLE`), two executors, closed
executor role.

Decisive evidence, verified against source on 2026-07-26:

1. **The planted defect is only lawful here.** `TimelockController` exposes
   `getTimestamp`/`getOperationState` as `public view virtual` hooks through
   which every readiness check routes — a ~10-line subclass override can
   weaken the delay check. Safe cannot support this: in v1.4.1,
   `checkSignatures`/`checkNSignatures` are not `virtual`; in v1.5.0 the
   whole of `Safe.sol` contains exactly one `virtual` function. A Safe defect
   variant would mean copying and editing audited production source —
   forbidden by the hard limits.
2. **Custody relevance.** The timelock is the enforced-delay-and-veto
   primitive placed in front of admin, upgrade, and treasury actions; its one
   job — nothing takes effect before a mandatory reaction window in which a
   separate role can cancel — is the property an institutional custodian
   certifies.
3. **Legible counterexamples.** Shrunk sequences read like an ops runbook
   (`schedule`, `warp`, `execute`); Safe sequences are dominated by 65-byte
   signature blobs.
4. **Hermeticity for free.** `pragma ^0.8.20`, plain constructor, zero
   external protocol dependencies (ADR-0003). Safe's official builds are
   solc 0.7.6 behind a proxy factory — added ceremony, no custody insight.

`Governor` rejected: a much larger surface (voting math, checkpoints,
ERC20Votes) whose failure modes are governance manipulation, not custody
control; the custody-relevant part of a Governor deployment *is* its
timelock.

## Consequences

- Trade-off accepted: Safe has bigger name recognition. The README notes the
  invariant family asserted here (delay integrity, role segregation, no
  double execution) is the same family a Safe suite would assert.
- TimelockController is functionally identical from v5.4.0 through v5.6.1
  (verified by diff: constant rename `_DONE_TIMESTAMP` → `DONE_TIMESTAMP` in
  v5.6.0, doc tweaks, `updateDelay` `external` → `public`); pinning the
  newest tag costs nothing.
- The defect variant (`test/defect/EagerTimelockController.sol`, M4) must
  preserve the `0`/`1` storage sentinels when overriding `getTimestamp`.
