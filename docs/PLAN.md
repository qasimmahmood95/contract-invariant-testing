# Milestone plan — contract-invariant-testing

Status: **executed through M5.** Approved at M0 (2026-07-26); the target
rationale became ADR-0001 and the methodology/hermeticity/determinism
sections ADRs 0002–0004. §3 carries the M4 implementation notes recording
where reality deviated from this plan. The README is the current front door;
this document is the plan of record.

## 1. Recommended target: OpenZeppelin `TimelockController` (pinned tag `v5.6.1`)

The system-under-test is the standard enforced-delay primitive placed in front
of admin, upgrade, and treasury actions across DeFi and institutional
deployments. Its one job is the property a custodian sells: **nothing the
keys authorize can take effect until a mandatory reaction window has passed,
during which a separate role can veto it.** Every invariant below is a facet
of that promise.

### Why TimelockController over a Safe core (the decisive evidence)

Safe was the other serious candidate and has the bigger name. It loses on a
hard feasibility fact plus three quality grounds — all verified against
source on 2026-07-26:

1. **The planted-defect methodology is impossible on Safe without violating
   our hard limits.** The defect must be a clearly-marked subclass that
   weakens one check. In `safe-smart-account` v1.4.1, `checkSignatures` and
   `checkNSignatures` are `public view` but **not `virtual`**; in v1.5.0 the
   entire `Safe.sol` contains exactly **one** `virtual` function (the
   `receive()` hook lives elsewhere in the inheritance chain). Weakening the
   threshold check would therefore require copying and editing audited
   production source — vendored-and-patched Safe is precisely what "no novel
   production Solidity, never patch the SUT" forbids. `TimelockController` is
   built for inheritance: `getTimestamp` and `getOperationState` are
   `public view virtual` hooks through which **all** readiness checks route,
   so the defect is a ~10-line override of a designed extension point.
2. **Legible counterexamples.** A shrunk Timelock sequence reads like an ops
   runbook — `schedule(...)`, `warp(...)`, `execute(...)` — matching the
   headline-artifact aesthetic of reconciliation-testing. A shrunk Safe
   sequence is dominated by 65-byte signature blobs.
3. **Hermeticity and fidelity for free.** `pragma ^0.8.20`, plain constructor
   deployment, zero external protocol dependencies — local deploy loses
   nothing versus a fork. Safe's official builds are solc 0.7.6 behind a
   proxy factory, adding a compile-fidelity caveat and deployment ceremony
   that buy no additional custody insight.
4. **A new adversarial dimension for the portfolio.** reconciliation-testing
   fuzzed *data and arrival order*; this repo fuzzes *state and time*
   (bounded `vm.warp` inside the invariant campaign). Same discipline,
   visibly extended.

`Governor` was rejected as a target: a far larger surface (voting math,
checkpoints, an ERC20Votes dependency) whose failure modes are governance
manipulation rather than custody control; the custody-relevant part of a
Governor deployment *is* its timelock.

Trade-off accepted: Safe recognition is higher. The README thesis will note
the invariants here (delay integrity, role segregation, no double execution)
are the same family a Safe suite would assert, and why the timelock is the
sound choice for a planted-defect demonstration.

### Deployment configuration under test

One self-administered instance, deployed locally in `setUp()`:
`admin = address(0)` (the timelock is its own `DEFAULT_ADMIN_ROLE`), two
proposer actors (who per constructor also hold `CANCELLER_ROLE`), two executor
actors, closed executor role (no `address(0)` grant), plus outsider actors
holding no roles. Operations target a `MockTarget` fixture that records every
call with its timestamp — the ground truth for "did anything execute early".

## 2. Invariants and the custody risk each maps to

Ghost truth lives in the handler: per-operation `scheduledAt`, `delayUsed`,
`readyAt = scheduledAt + delayUsed`, lifecycle status, plus expected
`minDelay`, expected role sets, and expected ETH balance. Invariants compare
the SUT against this harness-tracked truth, never against SUT-derived values.

| ID | Invariant | Custody risk if it ever breaks |
|----|-----------|--------------------------------|
| **INV-1 delay-integrity** | No operation ever executes before its ghost `readyAt`; execution at exactly `readyAt` is legal (boundary pinned by FZ-1). | The delay **is** the product: the window in which ops/compliance can detect and veto a compromised or malicious action. Early execution = zero-notice withdrawal. **Target of the planted defect.** |
| **INV-2 min-delay-floor** | Every accepted `schedule` used `delay >= minDelay` in force at that moment; every shorter attempt reverted. | One under-delayed operation silently shrinks the veto window below policy — the control still "exists" but no longer protects. |
| **INV-3 cancel-is-final** | A cancelled id returns to `Unset` and never executes; the only revival is a fresh `schedule` that restarts the full delay. `MockTarget` confirms no call lands after a cancel. | A vetoed withdrawal that later executes anyway nullifies the compliance veto — the exact control an institutional custodian certifies. |
| **INV-4 role-segregation** | Every observed transition was performed by the matching role (schedule ⇒ proposer, cancel ⇒ canceller, execute ⇒ executor); every attempt by any other actor reverted (ghost revert-counters prove the probes fired). | Maker/checker separation of duties. A bypass is a rogue employee acting alone with one key. |
| **INV-5 state-machine** | Every id is always in exactly one of `{Unset, Waiting, Ready, Done}`; transitions only along schedule/time/execute/cancel edges; `Done` is terminal — no re-execution and no re-schedule of a Done id. | Re-execution of a Done operation is on-chain **double settlement** — the same defect class the reconciliation repo's replay property guards off-chain. |
| **INV-6 self-administered-delay** | `minDelay` changes only at execution of a scheduled operation targeting the timelock's own `updateDelay`; direct calls from any account revert. | Instant delay reduction is the canonical attack precursor: shrink the window first, then push the real attack through it before anyone can react. |
| **INV-7 self-administered-roles** | Role membership changes only via operations executed through the timelock itself (no external admin exists in our config). | An out-of-band role grant is a backdoor signer added without delay or quorum — invisible key-ceremony bypass. |
| **INV-8 value-conservation** | Timelock ETH balance = handler funding − Σ value carried by executed operations; no other outflow path. | Assets leave treasury custody only through a scheduled, delayed, executed operation — "no unauthorized settlement" in on-chain form. |

### Targeted fuzz tests (example-shaped edges, complementing the campaign)

| ID | Property |
|----|----------|
| FZ-1 | Boundary precision: `execute` at exactly `readyAt` succeeds; at `readyAt − 1s` reverts `TimelockUnexpectedOperationState` (the on-chain sibling of reconciliation-testing's `2^53+1` boundary property). |
| FZ-2 | `schedule` with any `delay < minDelay` reverts, for every proposer. |
| FZ-3 | Re-scheduling any pending or Done id reverts; changing only the salt yields a fresh, independent id. |
| FZ-4 | An operation whose `predecessor` is not Done cannot execute at any warp. |
| FZ-5 | Caller matrix: random address × {schedule, cancel, execute, updateDelay, grantRole} succeeds iff the matching role is held (updateDelay: timelock only). |
| FZ-6 | Batch atomicity: length-mismatched `scheduleBatch` reverts; one failing inner call reverts the entire `executeBatch`. |

## 3. Planted defect and falsification design

**The one permitted buggy variant** — `test/defect/EagerTimelockController.sol`
(clearly bannered, on `main` under `test/defect/`, plus the red-by-design
branch below):

```solidity
/// @notice DELIBERATELY DEFECTIVE — TEST FIXTURE ONLY. Never deploy.
/// Plausible cover story: "ops asked for a grace window so executors can
/// batch transactions ahead of the exact readiness second."
contract EagerTimelockController is TimelockController {
    uint256 private constant _OPS_GRACE = 15 minutes;

    function getTimestamp(bytes32 id) public view override returns (uint256) {
        uint256 ts = super.getTimestamp(id);
        if (ts <= DONE_TIMESTAMP) return ts;          // preserve Unset/Done sentinels
        return ts > _OPS_GRACE ? ts - _OPS_GRACE : DONE_TIMESTAMP + 1;
    }
}
```

It is *quiet*: sentinels intact, every role check intact, all example-shaped
tests and 7 of 8 invariants stay green. Only sequences where the fuzzer warps
into the 15-minute pre-readiness window and executes there violate INV-1 —
exactly the kind of bug example-based tests never catch. Expected shrunk
sequence: `schedule(op, minDelay)` → `warp(< 15 min short of readyAt)` →
`execute(op)` — three calls.

**Presentation, mirroring reconciliation-testing:**

- `main` stays green and carries a `falsify` CI job: runs the invariant suite
  against the defective variant, **asserts the run fails**, extracts the
  shrunk sequence into the job summary and an artifact. The committed failure
  corpus makes it replay byte-for-byte locally.
- Branch `defect/eager-execution` points the standard suite at the variant —
  **red CI by design**; the README links that failing run as the headline
  artifact, exactly like the `defect/*` branches in reconciliation-testing.

**Falsification levers for everything else** (hard limit: only one buggy
Solidity variant, so the other levers sabotage the *harness*, not the SUT,
mirroring resilience-testing's `FALSIFY=<id>`): an env flag makes the handler
perturb its ghost accounting for one targeted invariant (e.g. under-count a
cancel for INV-3, skip a revert-probe counter for INV-4). `npm run falsify`
iterates all levers and requires every invariant to go red on its own lever.

**M4 implementation notes** (recorded honestly rather than papered over):

- The defect trips **INV-5 as well as INV-1**: in the grace window the SUT
  reports `Ready` where the ghost lifecycle expects `Waiting`, so the
  state-machine comparison sees the same lie the delay-integrity property
  does. The "7 of 8 invariants stay green" expectation above was written
  before INV-5 compared exact states. Both reds are genuine signal; the
  falsify gate pins INV-1 as the headline.
- **FZ-1 would independently catch this defect class** at the exact boundary
  (its `readyAt − 1s` leg executes early under the variant) — the
  example-shaped tests here are stronger than the typical unit tests the
  planted-defect story contrasts with. The `defect/eager-execution` branch
  flips only the invariant campaign's SUT default, so the campaign's shrunk
  sequence remains the artifact; FZ-1's redundancy is defense in depth, noted
  in the README at M5.
- The defect campaign shrinks to a **3-call counterexample**
  (`scheduleDelayUpdate → warpToBoundary → executeOp` — any schedule works;
  the fuzzer happened to pick the delay-update op), inside the planned ≤ 4.

## 4. Milestones (one PR each; code-review + verification subagents gate every PR)

| # | Milestone | Contents | Exit criteria |
|---|-----------|----------|---------------|
| M0 | **Plan** *(this doc)* | CLAUDE.md, PLAN.md, target rationale, invariant table | Owner sign-off — no code before this |
| M1 | **Scaffold & guardrails** | `git init` + public GitHub repo; `forge init`; OZ submodule pinned to `v5.6.1` tag commit + pinned `forge-std`; `foundry.toml` (pinned solc, seed `0x20260726`, pinned runs/depth/`shrink_run_limit`, `fail_on_revert = true`); gitleaks pre-commit + CI job; CI (pinned Foundry release): build + hermetic deploy smoke test; MIT LICENSE; README skeleton; ADRs 0001–0004 | CI green from clean clone with zero network beyond checkout+submodules |
| M2 | **Handler & invariant campaign** | `MockTarget` fixture; `TimelockHandler` (actors, ghost state, bounded actions incl. `vm.warp`, try/catch revert probes); INV-1…INV-8; invariant job in CI | Campaign green, deterministic across two consecutive CI runs; subagent gates pass |
| M3 | **Targeted fuzz & coverage** | FZ-1…FZ-6; `forge coverage` CI job (lcov artifact + summary filtered to `TimelockController.sol` + handlers) | Boundary tests pin the exact readiness second; coverage of SUT execution paths reported |
| M4 | **Planted defect & falsification** | `EagerTimelockController`; `falsify` harness + CI job (asserts red, publishes shrunk sequence); committed failure corpus; `defect/eager-execution` branch (red CI) | Verification subagent, from clean clone: main green; defect run fails INV-1 with a ≤ 4-call shrunk sequence; two runs byte-identical |
| M5 | **Release polish** | Full README (thesis + sibling links, invariant table, headline failing-run link, reproduce-from-clean-clone instructions, pinned-version record); badges; repo description/topics; final clean-clone verification | README headline artifact links resolve; a stranger can reproduce the counterexample with three commands |

## 5. Known risks / mitigations

- **Foundry shrink quality varies.** Mitigation: small handler action space,
  tightly bounded args, generous `shrink_run_limit`; the committed failure
  corpus plus a replaying repro test keep the headline artifact minimal even
  if a given campaign shrinks lazily.
- **Cross-version determinism.** Foundry seeds guarantee reproducibility only
  at a fixed forge release — pinned in CI, recorded in README; local drift
  documented rather than papered over.
- **`forge coverage` quirks** (optimizer off; possible stack-too-deep on some
  targets — unlikely for OZ; fallback `--ir-minimum`). Coverage numbers
  reported for the paths our suite exercises, filtered lcov, no vanity
  totals.
- **Wall-clock budget.** Invariant runs/depth tuned at M2 to keep the full CI
  suite ≤ ~5 minutes, matching the sibling repos' budget.

## 6. Open questions for the owner (M0 review)

1. **Target sign-off:** TimelockController v5.6.1 as argued above — or do you
   want Safe badly enough to accept a weaker defect story (defect would have
   to live in harness config, not a SUT subclass)?
2. **Merge protocol:** does the standing self-merge authorization from
   resilience-testing (2026-07-18) extend to this repo, or do you merge
   milestone PRs yourself? CLAUDE.md currently defaults to owner-merges.
3. **License:** MIT assumed, matching the sibling repos.
4. **Defect presentation:** both the green `falsify` job on `main` *and* the
   red `defect/eager-execution` branch are planned (mirroring
   reconciliation-testing). Confirm you want both, or trim to one.
