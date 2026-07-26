# ADR-0003: Local deploy in setUp() over a pinned mainnet fork

Status: Accepted
Date: 2026-07-26

## Context

Two hermetic-ish ways to put the SUT under test: (a) deploy the pinned source
locally in `setUp()`; (b) fork mainnet at a pinned block against a cached RPC
snapshot and test a live TimelockController instance.

## Decision

**Local deploy.** `TimelockController` has zero external protocol
dependencies — no oracles, no token integrations required for its core
guarantees, configuration fully determined by constructor arguments. A fork
would add an RPC provider, block pinning, and cache management to CI while
contributing nothing: the properties under test are properties of the
contract's own state machine, not of any particular mainnet deployment's
surroundings.

The SUT enters as a git submodule pinned to the `v5.6.1` tag commit and is
compiled from that source — the same bytes the audits cover. CI's only
network access is `git checkout` + submodules.

## Consequences

- CI can never flake or bit-rot on a third-party RPC endpoint; a clean clone
  reproduces everything offline after `git clone --recurse-submodules`.
- We compile at solc 0.8.28 (within the SUT's `^0.8.20` pragma). OZ's npm
  artifacts may be built with a different 0.8.x patch release; semantics
  within a pragma-compatible range are identical for this contract, and the
  suite tests source-level behavior, not deployed-bytecode identity.
- No claims are made about any specific production deployment's
  configuration; the deployment config under test (self-administered,
  closed executor role) is stated in ADR-0001 and asserted by the M1 smoke
  test.
