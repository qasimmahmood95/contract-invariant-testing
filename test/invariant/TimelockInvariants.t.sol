// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {MockTarget} from "../mocks/MockTarget.sol";
import {TimelockHandler} from "./handlers/TimelockHandler.sol";

/// M2 invariant campaign (docs/PLAN.md §2): the fuzzer drives adversarial call
/// sequences through TimelockHandler's bounded actions; after every call each
/// invariant below compares the SUT against the handler's ghost truth. With
/// fail_on_revert = true and every expected revert routed through explicit
/// try/catch probes, a silently reverting campaign cannot look green.
///
/// Falsification levers: each header names the FALSIFY=<id> perturbation
/// (implemented in TimelockHandler) that makes exactly this assertion go red;
/// the M4 harness will iterate them all. Levers may additionally trip
/// neighbouring invariants (e.g. a ghost-cancel that never reached the SUT
/// disturbs the state machine too) — the requirement is that each invariant's
/// own lever turns it red, proven deterministically before merge.
contract TimelockInvariants is Test {
    uint256 internal constant MIN_DELAY = 2 days; // must match TimelockHandler.ghost_minDelay init

    TimelockController internal timelock;
    MockTarget internal mockTarget;
    TimelockHandler internal handler;

    function setUp() public {
        address proposer1 = makeAddr("proposer1");
        address proposer2 = makeAddr("proposer2");
        address executor1 = makeAddr("executor1");
        address executor2 = makeAddr("executor2");
        address outsider = makeAddr("outsider");
        address probationer = makeAddr("probationer");

        address[] memory proposers = new address[](2);
        proposers[0] = proposer1;
        proposers[1] = proposer2;
        address[] memory executors = new address[](2);
        executors[0] = executor1;
        executors[1] = executor2;

        // Self-administered config under test (ADR-0001): no external admin,
        // closed executor role.
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));
        mockTarget = new MockTarget();
        handler = new TimelockHandler(
            timelock,
            mockTarget,
            [proposer1, proposer2],
            [executor1, executor2],
            outsider,
            probationer
        );

        // The campaign may only enter through the handler's bounded actions —
        // its view helpers and everything else stay out of the action space.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.schedulePinch.selector;
        selectors[2] = handler.scheduleDelayUpdate.selector;
        selectors[3] = handler.scheduleRoleChange.selector;
        selectors[4] = handler.executeOp.selector;
        selectors[5] = handler.cancelOp.selector;
        selectors[6] = handler.reviveCancelled.selector;
        selectors[7] = handler.warp.selector;
        selectors[8] = handler.warpToBoundary.selector;
        selectors[9] = handler.probeUnauthorizedSchedule.selector;
        selectors[10] = handler.probeUnauthorizedCancel.selector;
        selectors[11] = handler.probeUnauthorizedExecute.selector;
        selectors[12] = handler.probeDirectAdmin.selector;
        selectors[13] = handler.probeShortDelay.selector;
        selectors[14] = handler.probeResurrectDone.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// INV-1 delay-integrity.
    /// Property: no operation ever lands at MockTarget before its ghost
    ///           readyAt (SUT-independent call log vs handler bookkeeping),
    ///           and no execute ever succeeded while the ghost said Waiting.
    ///           Execution at exactly readyAt is legal (boundary pinned by the
    ///           wiring test today, FZ-1 at M3).
    /// Custody risk: the delay IS the product — the reaction window in which a
    ///           compromised or malicious action can be detected and vetoed.
    ///           Early execution = zero-notice withdrawal.
    /// Falsification lever: the planted defect variant (M4) executes inside a
    ///           15-minute grace window; harness lever FALSIFY=INV-1
    ///           over-records ghost readyAt by the same 15 minutes, so legal
    ///           near-boundary executions read as early — a red run that also
    ///           proves the campaign reaches the window the defect lives in.
    function invariant_INV1_delayIntegrity() public view {
        uint256 n = mockTarget.recordCount();
        for (uint256 i = 0; i < n; i++) {
            (uint256 nonce,, uint256 arrivedAt) = mockTarget.record(i);
            // Unknown nonces (a probe schedule that wrongly went through and
            // executed) panic on out-of-bounds here — also a red campaign.
            TimelockHandler.GhostOp memory op = handler.getOp(nonce);
            assertGe(arrivedAt, op.readyAt, "INV-1: call landed before ghost readyAt");
        }
        assertEq(
            handler.ghost_earlyExecuteSuccesses(), 0, "INV-1: execute succeeded before readyAt"
        );
    }

    /// INV-2 min-delay-floor.
    /// Property: every accepted schedule used delay >= the minDelay in force
    ///           at that moment (ghost-tracked), and every under-floor attempt
    ///           the probe fired was rejected.
    /// Custody risk: one under-delayed operation silently shrinks the veto
    ///           window below policy — the control "exists" but no longer
    ///           protects.
    /// Falsification lever: FALSIFY=INV-2 records the schedule-time floor one
    ///           second high, so at-the-floor schedules read as violations.
    function invariant_INV2_minDelayFloor() public view {
        uint256 n = handler.opCount();
        for (uint256 nonce = 0; nonce < n; nonce++) {
            TimelockHandler.GhostOp memory op = handler.getOp(nonce);
            assertGe(op.delayUsed, op.minDelayAtSchedule, "INV-2: scheduled below minDelay floor");
        }
        assertEq(
            handler.ghost_shortDelayAttempts(),
            handler.ghost_shortDelayReverts(),
            "INV-2: an under-minDelay schedule was accepted"
        );
    }

    /// INV-3 cancel-is-final.
    /// Property: every ghost-cancelled operation reads Unset in the SUT and
    ///           its payload never landed at MockTarget; every lawful cancel
    ///           and every revival (fresh schedule, full delay — enforced by
    ///           INV-1/INV-2 on the revived bookkeeping) was accepted.
    /// Custody risk: a vetoed withdrawal that later executes anyway nullifies
    ///           the compliance veto an institutional custodian certifies.
    /// Falsification lever: FALSIFY=INV-3 bookkeeps a cancel without
    ///           performing it — the ghost-cancelled id stays live in the SUT.
    function invariant_INV3_cancelIsFinal() public view {
        uint256 n = handler.opCount();
        for (uint256 nonce = 0; nonce < n; nonce++) {
            TimelockHandler.GhostOp memory op = handler.getOp(nonce);
            if (op.status != TimelockHandler.GhostStatus.Cancelled) continue;
            assertEq(
                uint256(timelock.getOperationState(op.id)),
                uint256(TimelockController.OperationState.Unset),
                "INV-3: cancelled id not Unset in SUT"
            );
            assertEq(
                mockTarget.callCountByNonce(nonce), 0, "INV-3: cancelled operation landed anyway"
            );
        }
        assertEq(handler.ghost_cancelFailures(), 0, "INV-3: lawful cancel rejected");
        assertEq(handler.ghost_reviveFailures(), 0, "INV-3: lawful revival rejected");
    }

    /// INV-4 role-segregation.
    /// Property: every unauthorized schedule/cancel/execute probe was
    ///           rejected (attempts == observed reverts, so a single quiet
    ///           success turns red). The positive direction — lawful
    ///           transitions performed by the matching role — holds by handler
    ///           construction: it pranks only role holders for lawful actions.
    /// Custody risk: maker/checker separation of duties; a bypass is a rogue
    ///           employee acting alone with one key.
    /// Falsification lever: FALSIFY=INV-4 stops counting observed reverts on
    ///           the unauthorized-schedule probe.
    function invariant_INV4_roleSegregation() public view {
        assertEq(
            handler.ghost_unauthorizedScheduleAttempts(),
            handler.ghost_unauthorizedScheduleReverts(),
            "INV-4: non-proposer scheduled"
        );
        assertEq(
            handler.ghost_unauthorizedCancelAttempts(),
            handler.ghost_unauthorizedCancelReverts(),
            "INV-4: non-canceller cancelled"
        );
        assertEq(
            handler.ghost_unauthorizedExecuteAttempts(),
            handler.ghost_unauthorizedExecuteReverts(),
            "INV-4: non-executor executed"
        );
    }

    /// INV-5 state-machine.
    /// Property: every ghost operation maps to exactly the SUT state the
    ///           lifecycle prescribes (Pending ⇒ Waiting before readyAt, Ready
    ///           from readyAt on; Cancelled ⇒ Unset; Executed ⇒ Done); Done is
    ///           terminal (resurrection probes all rejected); every lawful
    ///           schedule/execute was accepted; the ghost id derivation never
    ///           drifted from the SUT's.
    /// Custody risk: re-execution of a Done operation is on-chain double
    ///           settlement — the defect class the reconciliation repo's
    ///           replay property guards off-chain.
    /// Falsification lever: FALSIFY=INV-5 never marks executed ops Executed,
    ///           so the ghost lags the SUT state machine.
    function invariant_INV5_stateMachine() public view {
        uint256 n = handler.opCount();
        for (uint256 nonce = 0; nonce < n; nonce++) {
            TimelockHandler.GhostOp memory op = handler.getOp(nonce);
            TimelockController.OperationState expected;
            if (op.status == TimelockHandler.GhostStatus.Cancelled) {
                expected = TimelockController.OperationState.Unset;
            } else if (op.status == TimelockHandler.GhostStatus.Executed) {
                expected = TimelockController.OperationState.Done;
            } else {
                expected = block.timestamp < op.readyAt
                    ? TimelockController.OperationState.Waiting
                    : TimelockController.OperationState.Ready;
            }
            assertEq(
                uint256(timelock.getOperationState(op.id)),
                uint256(expected),
                "INV-5: SUT state diverged from ghost lifecycle"
            );
        }
        assertEq(handler.ghost_readyExecuteFailures(), 0, "INV-5: ripe execute rejected");
        assertEq(handler.ghost_scheduleFailures(), 0, "INV-5: lawful schedule rejected");
        assertEq(handler.ghost_idMismatches(), 0, "INV-5: ghost id derivation drifted");
        assertEq(
            handler.ghost_resurrectScheduleAttempts(),
            handler.ghost_resurrectScheduleReverts(),
            "INV-5: Done id re-scheduled"
        );
        assertEq(
            handler.ghost_resurrectExecuteAttempts(),
            handler.ghost_resurrectExecuteReverts(),
            "INV-5: Done id re-executed"
        );
    }

    /// INV-6 self-administered-delay.
    /// Property: the SUT's minDelay always equals the ghost value, which moves
    ///           only when a scheduled updateDelay operation executes; every
    ///           direct updateDelay call from any non-timelock account was
    ///           rejected.
    /// Custody risk: instant delay reduction is the canonical attack precursor
    ///           — shrink the window first, then push the real attack through
    ///           it before anyone can react.
    /// Falsification lever: FALSIFY=INV-6 skips the ghost minDelay update when
    ///           a delay-update operation executes.
    function invariant_INV6_selfAdministeredDelay() public view {
        assertEq(
            timelock.getMinDelay(), handler.ghost_minDelay(), "INV-6: minDelay changed off-ledger"
        );
        assertEq(
            handler.ghost_directDelayAttempts(),
            handler.ghost_directDelayReverts(),
            "INV-6: direct updateDelay accepted"
        );
    }

    /// INV-7 self-administered-roles.
    /// Property: the full tracked role matrix (4 roles x every actor, the
    ///           handler and the timelock itself) always equals the ghost
    ///           matrix, which moves only when a role operation executes
    ///           through the timelock; every direct grant/revoke was rejected.
    /// Custody risk: an out-of-band role grant is a backdoor signer added
    ///           without delay or quorum — an invisible key-ceremony bypass.
    /// Falsification lever: FALSIFY=INV-7 skips the ghost matrix update when a
    ///           role operation executes.
    function invariant_INV7_selfAdministeredRoles() public view {
        bytes32[] memory roles = handler.trackedRoles();
        address[] memory accounts = handler.trackedAccounts();
        for (uint256 r = 0; r < roles.length; r++) {
            for (uint256 a = 0; a < accounts.length; a++) {
                assertEq(
                    timelock.hasRole(roles[r], accounts[a]),
                    handler.ghostRole(roles[r], accounts[a]),
                    "INV-7: role membership changed off-ledger"
                );
            }
        }
        assertEq(
            handler.ghost_directRoleAttempts(),
            handler.ghost_directRoleReverts(),
            "INV-7: direct grant/revoke accepted"
        );
    }

    /// INV-8 value-conservation.
    /// Property: timelock balance == everything the handler ever funded minus
    ///           the value carried out by executed operations, all of which
    ///           sits at MockTarget — a closed system with no other outflow
    ///           path; funding never failed.
    /// Custody risk: assets leaving treasury custody other than through a
    ///           scheduled, delayed, executed operation is unauthorized
    ///           settlement in on-chain form.
    /// Falsification lever: FALSIFY=INV-8 skips outflow accounting when a
    ///           value-carrying operation executes.
    function invariant_INV8_valueConservation() public view {
        assertEq(
            address(timelock).balance,
            handler.ghost_funded() - handler.ghost_outflow(),
            "INV-8: treasury balance off ledger"
        );
        assertEq(
            address(mockTarget).balance, handler.ghost_outflow(), "INV-8: outflow leaked elsewhere"
        );
        assertEq(handler.ghost_fundFailures(), 0, "INV-8: funding rejected");
    }

    // Deliberately no afterInvariant() non-vacuity floor: the shrinker treats
    // an afterInvariant failure as "sequence still fails", so any campaign
    // floor like "opCount > 0" lets counterexamples collapse into meaningless
    // 1-call sequences (verified against forge v1.7.1) — ruining the shrunk
    // artifact the falsification runs exist to produce. Non-vacuity is instead
    // pinned deterministically in HandlerWiring.t.sol (every action and probe
    // demonstrably live) and visible in the per-selector metrics table of
    // every campaign run.
}
