// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {MockTarget} from "../mocks/MockTarget.sol";
import {TimelockHandler} from "./handlers/TimelockHandler.sol";

/// Deterministic non-vacuity proof for the M2 campaign (CLAUDE.md hard
/// limit 3): with fixed seeds, every handler action visibly moves ghost +
/// SUT state and every must-revert probe fires and is rejected exactly once.
/// The campaign itself deliberately carries no afterInvariant() non-vacuity
/// floor (it would wreck shrinking — see TimelockInvariants.t.sol), so this
/// test is where liveness is pinned, independent of campaign randomness.
///
/// Property: each handler action/probe is live (not a silent no-op) and its
///           ghost bookkeeping matches the SUT effect it wraps.
/// Custody risk: none directly — this guards the guard: a dead probe or dead
///           action would let the invariant campaign pass vacuously.
/// Falsification lever: disconnect any probe's counter or any action's
///           bookkeeping in TimelockHandler (that is precisely what the
///           FALSIFY levers do; e.g. FALSIFY=INV-4 makes this test fail at
///           the unauthorized-schedule pair below).
contract HandlerWiringTest is Test {
    uint256 internal constant MIN_DELAY = 2 days;

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

        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));
        mockTarget = new MockTarget();
        handler = new TimelockHandler(
            timelock,
            mockTarget,
            [proposer1, proposer2],
            [executor1, executor2],
            outsider,
            probationer,
            MIN_DELAY
        );
    }

    function test_everyActionAndProbeIsLive() public {
        uint256 window = handler.BOUNDARY_WINDOW();
        uint256 treasury = handler.INITIAL_TREASURY();

        // schedulePinch: nonce 0, 5 ether, exactly minDelay.
        uint256 t0 = block.timestamp;
        handler.schedulePinch(0, 5 ether, MIN_DELAY);
        assertEq(handler.opCount(), 1, "schedule recorded");
        assertEq(handler.ghost_scheduleCount(), 1);
        TimelockHandler.GhostOp memory op0 = handler.getOp(0);
        assertEq(op0.readyAt, t0 + MIN_DELAY, "ghost readyAt");
        assertTrue(timelock.isOperationPending(op0.id), "SUT pending");

        // executeOp before readiness: probe fires, SUT rejects, ghost counts.
        handler.executeOp(0, 0);
        assertEq(handler.ghost_earlyExecuteAttempts(), 1);
        assertEq(handler.ghost_earlyExecuteReverts(), 1);
        assertEq(handler.ghost_earlyExecuteSuccesses(), 0);
        assertEq(handler.ghost_executedCount(), 0);

        // warpToBoundary with centre offset lands exactly on readyAt;
        // executeOp there succeeds — the boundary second is legal (INV-1).
        handler.warpToBoundary(0, window);
        assertEq(block.timestamp, op0.readyAt, "warped to exact boundary");
        handler.executeOp(1, 0);
        assertEq(handler.ghost_executedCount(), 1, "boundary execute succeeded");
        assertEq(mockTarget.recordCount(), 1);
        (uint256 recNonce, uint256 recValue, uint256 recAt) = mockTarget.record(0);
        assertEq(recNonce, 0);
        assertEq(recValue, 5 ether);
        assertEq(recAt, op0.readyAt, "landed at exactly readyAt");
        assertEq(handler.ghost_outflow(), 5 ether);
        assertEq(address(timelock).balance, treasury - 5 ether);
        assertEq(address(mockTarget).balance, 5 ether);
        assertTrue(timelock.isOperationDone(op0.id));

        // Done is terminal: both resurrection probes fire and are rejected.
        handler.probeResurrectDone(0, 0, 0);
        handler.probeResurrectDone(0, 0, 1);
        assertEq(handler.ghost_resurrectScheduleAttempts(), 1);
        assertEq(handler.ghost_resurrectScheduleReverts(), 1);
        assertEq(handler.ghost_resurrectExecuteAttempts(), 1);
        assertEq(handler.ghost_resurrectExecuteReverts(), 1);

        // cancel + revive round-trip on a fresh operation.
        handler.schedulePinch(1, 0, MIN_DELAY); // nonce 1
        handler.cancelOp(0, 0);
        assertEq(handler.ghost_cancelCount(), 1);
        TimelockHandler.GhostOp memory op1 = handler.getOp(1);
        assertTrue(op1.status == TimelockHandler.GhostStatus.Cancelled, "ghost cancelled");
        assertEq(
            uint256(timelock.getOperationState(op1.id)),
            uint256(TimelockController.OperationState.Unset),
            "SUT unset after cancel"
        );
        handler.reviveCancelled(0, 0, MIN_DELAY);
        assertEq(handler.ghost_reviveCount(), 1);
        op1 = handler.getOp(1);
        assertTrue(op1.status == TimelockHandler.GhostStatus.Pending, "ghost revived");
        assertEq(op1.readyAt, block.timestamp + MIN_DELAY, "revival restarts the full delay");
        assertTrue(timelock.isOperationPending(op1.id), "SUT pending again");

        // Every must-revert probe fires exactly once and is rejected.
        handler.probeShortDelay(0, 0);
        assertEq(handler.ghost_shortDelayAttempts(), 1);
        assertEq(handler.ghost_shortDelayReverts(), 1);

        handler.probeUnauthorizedSchedule(0, MIN_DELAY);
        assertEq(handler.ghost_unauthorizedScheduleAttempts(), 1);
        assertEq(handler.ghost_unauthorizedScheduleReverts(), 1);

        handler.probeUnauthorizedCancel(0, 0);
        assertEq(handler.ghost_unauthorizedCancelAttempts(), 1);
        assertEq(handler.ghost_unauthorizedCancelReverts(), 1);

        handler.probeUnauthorizedExecute(0, 0);
        assertEq(handler.ghost_unauthorizedExecuteAttempts(), 1);
        assertEq(handler.ghost_unauthorizedExecuteReverts(), 1);

        handler.probeDirectAdmin(0, 0, 3 days); // direct updateDelay
        assertEq(handler.ghost_directDelayAttempts(), 1);
        assertEq(handler.ghost_directDelayReverts(), 1);
        handler.probeDirectAdmin(2, 1, 0); // direct grantRole by outsider
        handler.probeDirectAdmin(3, 2, 0); // direct revokeRole by the handler
        assertEq(handler.ghost_directRoleAttempts(), 2);
        assertEq(handler.ghost_directRoleReverts(), 2);

        // Lawful minDelay change: schedule -> wait -> execute, ghost follows.
        handler.scheduleDelayUpdate(0, 3 days, MIN_DELAY); // nonce 2
        handler.warpToBoundary(1, 2 * window); // readyAt(nonce 2) + window
        handler.executeOp(0, 1);
        assertEq(handler.ghost_minDelay(), 3 days, "ghost minDelay follows execution");
        assertEq(timelock.getMinDelay(), 3 days, "SUT minDelay updated");

        // Lawful role change for the probationer, same lifecycle.
        handler.scheduleRoleChange(0, 2, 3 days); // grant EXECUTOR_ROLE, nonce 3
        handler.warpToBoundary(1, 2 * window);
        handler.executeOp(1, 1);
        bytes32 executorRole = handler.executorRole();
        assertTrue(handler.ghostRole(executorRole, handler.probationer()), "ghost role granted");
        assertTrue(timelock.hasRole(executorRole, handler.probationer()), "SUT role granted");

        // fund + warp keep their books.
        handler.fund(10 ether);
        assertEq(handler.ghost_fundCount(), 1);
        assertEq(handler.ghost_funded(), treasury + 10 ether);
        assertEq(address(timelock).balance, handler.ghost_funded() - handler.ghost_outflow());
        uint256 before = block.timestamp;
        handler.warp(1 days);
        assertEq(block.timestamp, before + 1 days, "warp moved time forward");

        assertEq(handler.ghost_noopCalls(), 0, "no action silently no-opped in this script");
    }
}
