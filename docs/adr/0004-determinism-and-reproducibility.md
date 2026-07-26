# ADR-0004: Determinism and reproducibility

Status: Accepted
Date: 2026-07-26

## Context

The repo's headline artifact is a fuzzer-found, shrunk counterexample. That
artifact is only credible if a stranger can reproduce it byte-for-byte from a
clean clone — the reconciliation-testing standard (`FC_SEED=20260718`),
carried on-chain.

## Decision

- **Seed pinned** in `foundry.toml`: `seed = "0x20260726"` (date-stamped).
  It governs both fuzz and invariant campaigns.
- **Campaign shape pinned**: `[fuzz] runs`, `[invariant] runs`, `depth`,
  `shrink_run_limit` are fixed in `foundry.toml`; no per-run overrides in CI.
- **Toolchain pinned**: forge `v1.7.1` (CI + README; Foundry guarantees
  seed-stable campaigns only per release), solc `0.8.28`, `evm_version`
  `cancun`, optimizer settings fixed, SUT submodule at the `v5.6.1` tag
  commit. Any pin change is its own commit with rationale.
- **Failure corpus committed**: `failure_persist_dir` points into
  `test/failures/` (not gitignored). From M4, the defect counterexample is
  committed so it replays as a regression without re-searching.
- **No ambient nondeterminism in test code**: no wall-clock reads, no
  unseeded randomness; time moves only via bounded `vm.warp` handler
  actions; all bounds are named constants.
- **Byte-stable sources**: LF everywhere via `.gitattributes`.

## Consequences

- `git clone --recurse-submodules && forge test` reproduces CI exactly at the
  pinned toolchain; the README reproducibility section records the pins.
- Runs on a different forge release may fuzz different sequences — that is
  documented drift, not flake; the committed corpus still replays the
  headline counterexample on any release.
- CI wall-time stays bounded (≤ ~5 min target) because campaign shape cannot
  silently grow.
