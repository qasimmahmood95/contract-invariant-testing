// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockTarget} from "../../mocks/MockTarget.sol";

/// Invariant-campaign handler for the self-administered TimelockController
/// deployment under test (ADR-0001). All fuzzer entropy enters through the
/// bounded action functions below; the SUT is only ever touched through them.
///
/// Ghost truth (docs/PLAN.md §2): per-operation schedule bookkeeping, expected
/// minDelay, expected role matrix, expected ETH flows, and revert-probe
/// counters all live here, derived from handler-side knowledge only — never
/// from SUT reads. The invariants in ../TimelockInvariants.t.sol compare the
/// SUT against this state.
///
/// Determinism (ADR-0004): every input is bounded by the named constants
/// below; time moves only forward via bounded vm.warp actions; expected-revert
/// probes go through explicit try/catch with ghost counters, so with
/// fail_on_revert = true a silently reverting campaign cannot look green.
///
/// Falsification levers (CLAUDE.md hard limit 3): FALSIFY=INV-<n> perturbs the
/// ghost accounting for exactly that invariant, proving the assertion has
/// teeth without touching the SUT. Lever map:
///   INV-1  ghost readyAt over-recorded by 15 min → legal near-boundary executions read
///          early (same width as the planted defect's grace window, so a red run here
///          also proves the campaign reaches the window the M4 defect lives in)
///   INV-2  ghost minDelay-at-schedule +1      → at-the-floor schedules read under-delayed
///   INV-3  cancel bookkept but not performed  → ghost-cancelled id stays live in SUT
///   INV-4  unauthorized-schedule probe stops counting observed reverts
///   INV-5  executed ops never marked Executed → ghost lags the SUT state machine
///   INV-6  executed delay-updates skip ghost minDelay update
///   INV-7  executed role-changes skip ghost role-matrix update
///   INV-8  executed value transfers skip ghost outflow accounting
/// (INV-1's headline lever is the planted defect variant, M4; the harness
/// lever above additionally proves the assertion itself can fail.)
contract TimelockHandler is Test {
    // ── Bounds: every fuzzed input is clamped by these named constants. ──
    uint256 public constant INITIAL_TREASURY = 10_000 ether; // covers any depth ≤ 1000 at MAX_OP_VALUE
    uint256 public constant MAX_FUND = 50 ether;
    uint256 public constant MAX_OP_VALUE = 10 ether;
    uint256 public constant MAX_EXTRA_DELAY = 7 days; // schedule delay ∈ [minDelay, minDelay + this]
    uint256 public constant MIN_NEW_DELAY = 1 days; // updateDelay payload lower bound (keeps
    uint256 public constant MAX_NEW_DELAY = 30 days; // the short-delay probe range non-empty)
    uint256 public constant MIN_WARP = 1 hours;
    uint256 public constant MAX_WARP = 3 days;
    uint256 public constant BOUNDARY_WINDOW = 1 hours; // warpToBoundary lands in readyAt ± this
    // Probe schedules must never collide with real ghost nonces (< campaign depth).
    uint256 internal constant PROBE_NONCE_BASE = 1e18;
    // FALSIFY=INV-1 margin: as wide as the planted defect's grace window (M4),
    // so the sabotage is reachable by the same boundary-focused sequences.
    uint256 internal constant LEVER_EARLY_MARGIN = 15 minutes;

    enum GhostStatus {
        Pending,
        Cancelled,
        Executed
    }

    enum OpKind {
        Pinch,
        DelayUpdate,
        RoleGrant,
        RoleRevoke
    }

    struct GhostOp {
        bytes32 id;
        OpKind kind;
        GhostStatus status;
        address opTarget;
        uint256 value;
        bytes data;
        bytes32 salt;
        uint256 scheduledAt;
        uint256 delayUsed;
        uint256 readyAt;
        uint256 minDelayAtSchedule;
        uint256 executedAt;
        bytes32 roleArg;
        address accountArg;
        uint256 newDelayArg;
    }

    TimelockController public immutable timelock;
    MockTarget public immutable mockTarget;

    // Actors. Proposers double as cancellers (constructor wiring). The
    // outsider never holds any role; the probationer only ever gains or loses
    // roles via operations executed through the timelock itself (INV-7) and
    // never acts, so every must-revert probe caller set stays must-revert.
    address[2] public proposers;
    address[2] public executors;
    address public outsider;
    address public probationer;

    bytes32 public immutable proposerRole;
    bytes32 public immutable cancellerRole;
    bytes32 public immutable executorRole;
    bytes32 public immutable adminRole;

    // ── Ghost state (harness truth, never SUT-derived). ──
    GhostOp[] internal _ops;
    uint256[] internal _pending; // nonces with ghost status Pending
    uint256[] internal _cancelled; // nonces with ghost status Cancelled
    uint256[] internal _executed; // nonces with ghost status Executed
    mapping(uint256 nonce => uint256 posPlusOne) internal _pendingPos;
    mapping(uint256 nonce => uint256 posPlusOne) internal _cancelledPos;

    uint256 public ghost_minDelay;
    uint256 public ghost_funded;
    uint256 public ghost_outflow;
    mapping(bytes32 role => mapping(address account => bool)) public ghostRole;
    bytes32[] internal _trackedRoles;
    address[] internal _trackedAccounts;

    // Action / anomaly counters. "Attempts == reverts" pairs prove the
    // must-revert probes fired and were rejected; the *Failures counters
    // record legal actions the SUT unexpectedly refused (always asserted 0).
    uint256 public ghost_scheduleCount;
    uint256 public ghost_scheduleFailures;
    uint256 public ghost_idMismatches;
    uint256 public ghost_cancelCount;
    uint256 public ghost_cancelFailures;
    uint256 public ghost_reviveCount;
    uint256 public ghost_reviveFailures;
    uint256 public ghost_executedCount;
    uint256 public ghost_readyExecuteFailures;
    uint256 public ghost_earlyExecuteAttempts;
    uint256 public ghost_earlyExecuteReverts;
    uint256 public ghost_earlyExecuteSuccesses;
    uint256 public ghost_fundCount;
    uint256 public ghost_fundFailures;
    uint256 public ghost_warpCount;
    uint256 public ghost_shortDelayAttempts;
    uint256 public ghost_shortDelayReverts;
    uint256 public ghost_unauthorizedScheduleAttempts;
    uint256 public ghost_unauthorizedScheduleReverts;
    uint256 public ghost_unauthorizedCancelAttempts;
    uint256 public ghost_unauthorizedCancelReverts;
    uint256 public ghost_unauthorizedExecuteAttempts;
    uint256 public ghost_unauthorizedExecuteReverts;
    uint256 public ghost_directDelayAttempts;
    uint256 public ghost_directDelayReverts;
    uint256 public ghost_directRoleAttempts;
    uint256 public ghost_directRoleReverts;
    uint256 public ghost_resurrectScheduleAttempts;
    uint256 public ghost_resurrectScheduleReverts;
    uint256 public ghost_resurrectExecuteAttempts;
    uint256 public ghost_resurrectExecuteReverts;
    uint256 public ghost_noopCalls;

    bytes32 private immutable _falsify;

    constructor(
        TimelockController timelock_,
        MockTarget mockTarget_,
        address[2] memory proposers_,
        address[2] memory executors_,
        address outsider_,
        address probationer_,
        uint256 initialMinDelay_
    ) {
        timelock = timelock_;
        mockTarget = mockTarget_;
        proposers = proposers_;
        executors = executors_;
        outsider = outsider_;
        probationer = probationer_;

        proposerRole = timelock_.PROPOSER_ROLE();
        cancellerRole = timelock_.CANCELLER_ROLE();
        executorRole = timelock_.EXECUTOR_ROLE();
        adminRole = timelock_.DEFAULT_ADMIN_ROLE();

        _falsify = keccak256(bytes(vm.envOr("FALSIFY", string(""))));

        ghost_minDelay = initialMinDelay_; // the minDelay the timelock was deployed with

        // Expected role matrix per constructor wiring (ADR-0001): proposers
        // get PROPOSER + CANCELLER, executors get EXECUTOR, the timelock
        // administers itself, nobody else holds anything.
        _trackedRoles = [proposerRole, cancellerRole, executorRole, adminRole];
        _trackedAccounts = [
            proposers_[0],
            proposers_[1],
            executors_[0],
            executors_[1],
            outsider_,
            probationer_,
            address(this),
            address(timelock_)
        ];
        ghostRole[proposerRole][proposers_[0]] = true;
        ghostRole[proposerRole][proposers_[1]] = true;
        ghostRole[cancellerRole][proposers_[0]] = true;
        ghostRole[cancellerRole][proposers_[1]] = true;
        ghostRole[executorRole][executors_[0]] = true;
        ghostRole[executorRole][executors_[1]] = true;
        ghostRole[adminRole][address(timelock_)] = true;

        // Treasury under custody: funded here, leaves only via executed ops (INV-8).
        vm.deal(address(this), INITIAL_TREASURY * 100);
        (bool ok,) = payable(address(timelock_)).call{value: INITIAL_TREASURY}("");
        require(ok, "treasury funding failed");
        ghost_funded = INITIAL_TREASURY;
    }

    // ─────────────────────────── core actions ───────────────────────────

    /// Send more ETH into custody. Inflow is tracked so INV-8 stays exact.
    function fund(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, MAX_FUND);
        (bool ok,) = payable(address(timelock)).call{value: amount}("");
        if (ok) {
            ghost_funded += amount;
            ghost_fundCount++;
        } else {
            ghost_fundFailures++;
        }
    }

    /// Proposer schedules a value-carrying call to MockTarget.pinch(nonce).
    function schedulePinch(uint256 actorSeed, uint256 valueSeed, uint256 delaySeed) external {
        uint256 nonce = _ops.length;
        GhostOp memory op;
        op.kind = OpKind.Pinch;
        op.opTarget = address(mockTarget);
        op.value = bound(valueSeed, 0, MAX_OP_VALUE);
        op.data = abi.encodeCall(MockTarget.pinch, (nonce));
        _scheduleNew(op, actorSeed, delaySeed);
    }

    /// Proposer schedules the only lawful minDelay change: the timelock
    /// calling its own updateDelay after the full waiting period (INV-6).
    function scheduleDelayUpdate(uint256 actorSeed, uint256 newDelaySeed, uint256 delaySeed)
        external
    {
        uint256 newDelay = bound(newDelaySeed, MIN_NEW_DELAY, MAX_NEW_DELAY);
        GhostOp memory op;
        op.kind = OpKind.DelayUpdate;
        op.opTarget = address(timelock);
        op.data = abi.encodeCall(TimelockController.updateDelay, (newDelay));
        op.newDelayArg = newDelay;
        _scheduleNew(op, actorSeed, delaySeed);
    }

    /// Proposer schedules a role grant/revoke for the probationer — the only
    /// lawful way membership ever changes in this config (INV-7). Grant vs
    /// revoke toggles on the ghost matrix so both edges get exercised.
    function scheduleRoleChange(uint256 actorSeed, uint256 roleSeed, uint256 delaySeed) external {
        bytes32 role = _trackedRoles[bound(roleSeed, 0, 2)]; // proposer/canceller/executor
        bool grant = !ghostRole[role][probationer];
        GhostOp memory op;
        op.kind = grant ? OpKind.RoleGrant : OpKind.RoleRevoke;
        op.opTarget = address(timelock);
        op.data = grant
            ? abi.encodeCall(IAccessControl.grantRole, (role, probationer))
            : abi.encodeCall(IAccessControl.revokeRole, (role, probationer));
        op.roleArg = role;
        op.accountArg = probationer;
        _scheduleNew(op, actorSeed, delaySeed);
    }

    /// Executor attempts execution of a pending operation. Expected outcome is
    /// decided by ghost readyAt alone: too-early attempts must revert (INV-1),
    /// ripe attempts must succeed (inner calls cannot fail by construction).
    function executeOp(uint256 actorSeed, uint256 opSeed) external {
        if (_pending.length == 0) {
            ghost_noopCalls++;
            return;
        }
        uint256 nonce = _pending[bound(opSeed, 0, _pending.length - 1)];
        GhostOp storage op = _ops[nonce];
        bool expectReady = block.timestamp >= op.readyAt;
        if (!expectReady) ghost_earlyExecuteAttempts++;

        vm.prank(executors[bound(actorSeed, 0, 1)]);
        try timelock.execute(op.opTarget, op.value, op.data, bytes32(0), op.salt) {
            if (!expectReady) ghost_earlyExecuteSuccesses++;
            _applyExecuteEffects(nonce, op);
        } catch {
            if (expectReady) ghost_readyExecuteFailures++;
            else ghost_earlyExecuteReverts++;
        }
    }

    /// Canceller vetoes a pending (Waiting or Ready) operation (INV-3).
    function cancelOp(uint256 actorSeed, uint256 opSeed) external {
        if (_pending.length == 0) {
            ghost_noopCalls++;
            return;
        }
        uint256 nonce = _pending[bound(opSeed, 0, _pending.length - 1)];
        if (_lever("INV-3")) {
            // Sabotage: bookkeep the veto without performing it.
            _markCancelled(nonce);
            ghost_cancelCount++;
            return;
        }
        vm.prank(proposers[bound(actorSeed, 0, 1)]); // proposers hold CANCELLER_ROLE
        try timelock.cancel(_ops[nonce].id) {
            _markCancelled(nonce);
            ghost_cancelCount++;
        } catch {
            ghost_cancelFailures++;
        }
    }

    /// Re-schedule a cancelled operation: same id, full delay restarts (INV-3).
    function reviveCancelled(uint256 actorSeed, uint256 opSeed, uint256 delaySeed) external {
        if (_cancelled.length == 0) {
            ghost_noopCalls++;
            return;
        }
        uint256 nonce = _cancelled[bound(opSeed, 0, _cancelled.length - 1)];
        GhostOp storage op = _ops[nonce];
        uint256 delay = bound(delaySeed, ghost_minDelay, ghost_minDelay + MAX_EXTRA_DELAY);

        vm.prank(proposers[bound(actorSeed, 0, 1)]);
        try timelock.schedule(op.opTarget, op.value, op.data, bytes32(0), op.salt, delay) {
            op.status = GhostStatus.Pending;
            op.scheduledAt = block.timestamp;
            op.delayUsed = delay;
            op.readyAt = block.timestamp + delay + (_lever("INV-1") ? LEVER_EARLY_MARGIN : 0);
            op.minDelayAtSchedule = ghost_minDelay + (_lever("INV-2") ? 1 : 0);
            op.executedAt = 0;
            _cancelledRemove(nonce);
            _pendingAdd(nonce);
            ghost_reviveCount++;
            ghost_scheduleCount++;
        } catch {
            ghost_reviveFailures++;
        }
    }

    /// Bounded forward time travel — the only way time moves (ADR-0004).
    function warp(uint256 deltaSeed) external {
        vm.warp(block.timestamp + bound(deltaSeed, MIN_WARP, MAX_WARP));
        ghost_warpCount++;
    }

    /// Land near a pending operation's readiness second (readyAt ± 1h, never
    /// backwards). Concentrates the campaign on the INV-1 boundary, where the
    /// planted defect (M4) lives.
    function warpToBoundary(uint256 opSeed, uint256 offsetSeed) external {
        if (_pending.length == 0) {
            ghost_noopCalls++;
            return;
        }
        uint256 nonce = _pending[bound(opSeed, 0, _pending.length - 1)];
        // readyAt ≥ scheduledAt + MIN_NEW_DELAY >> BOUNDARY_WINDOW, so no underflow.
        uint256 t =
            _ops[nonce].readyAt + bound(offsetSeed, 0, 2 * BOUNDARY_WINDOW) - BOUNDARY_WINDOW;
        if (t < block.timestamp) t = block.timestamp;
        vm.warp(t);
        ghost_warpCount++;
    }

    // ─────────────────────── must-revert probes ───────────────────────
    // Each probe records attempts and observed reverts; the invariants assert
    // the pairs are equal, so a single quiet success turns the campaign red.

    /// Non-proposers must never be able to schedule (INV-4).
    function probeUnauthorizedSchedule(uint256 actorSeed, uint256 delaySeed) external {
        address[3] memory callers = [executors[0], executors[1], outsider];
        address caller = callers[bound(actorSeed, 0, 2)];
        uint256 delay = bound(delaySeed, ghost_minDelay, ghost_minDelay + MAX_EXTRA_DELAY);
        ghost_unauthorizedScheduleAttempts++;
        bytes memory data = abi.encodeCall(
            MockTarget.pinch, (PROBE_NONCE_BASE + ghost_unauthorizedScheduleAttempts)
        );
        bytes32 salt = keccak256(abi.encode("unauth-schedule", ghost_unauthorizedScheduleAttempts));

        vm.prank(caller);
        try timelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, delay) {
        // Quiet success would leave reverts < attempts — INV-4 goes red.
        }
        catch {
            if (!_lever("INV-4")) ghost_unauthorizedScheduleReverts++;
        }
    }

    /// Non-cancellers must never be able to cancel (INV-4).
    function probeUnauthorizedCancel(uint256 actorSeed, uint256 opSeed) external {
        address[3] memory callers = [executors[0], executors[1], outsider];
        address caller = callers[bound(actorSeed, 0, 2)];
        bytes32 id = _pending.length > 0
            ? _ops[_pending[bound(opSeed, 0, _pending.length - 1)]].id
            : keccak256("no-such-operation");
        ghost_unauthorizedCancelAttempts++;

        vm.prank(caller);
        try timelock.cancel(id) {}
        catch {
            ghost_unauthorizedCancelReverts++;
        }
    }

    /// Non-executors must never be able to execute — the role check fires
    /// before any readiness logic, so ripeness is irrelevant here (INV-4).
    function probeUnauthorizedExecute(uint256 actorSeed, uint256 opSeed) external {
        address[3] memory callers = [proposers[0], proposers[1], outsider];
        address caller = callers[bound(actorSeed, 0, 2)];
        ghost_unauthorizedExecuteAttempts++;

        address opTarget;
        uint256 value;
        bytes memory data;
        bytes32 salt;
        if (_pending.length > 0) {
            GhostOp storage op = _ops[_pending[bound(opSeed, 0, _pending.length - 1)]];
            (opTarget, value, data, salt) = (op.opTarget, op.value, op.data, op.salt);
        } else {
            opTarget = address(mockTarget);
            data = abi.encodeCall(MockTarget.pinch, (PROBE_NONCE_BASE));
            salt = keccak256("unauth-execute");
        }

        vm.prank(caller);
        try timelock.execute(opTarget, value, data, bytes32(0), salt) {}
        catch {
            ghost_unauthorizedExecuteReverts++;
        }
    }

    /// Direct administration must be impossible for every non-timelock caller:
    /// updateDelay is self-only (INV-6); grant/revoke require the admin role
    /// only the timelock holds (INV-7).
    function probeDirectAdmin(uint256 actorSeed, uint256 callSeed, uint256 newDelaySeed) external {
        address[4] memory callers = [proposers[0], executors[0], outsider, address(this)];
        address caller = callers[bound(actorSeed, 0, 3)];
        uint256 which = bound(callSeed, 0, 2);

        if (which == 0) {
            ghost_directDelayAttempts++;
            uint256 newDelay = bound(newDelaySeed, MIN_NEW_DELAY, MAX_NEW_DELAY);
            vm.prank(caller);
            try timelock.updateDelay(newDelay) {}
            catch {
                ghost_directDelayReverts++;
            }
        } else if (which == 1) {
            ghost_directRoleAttempts++;
            vm.prank(caller);
            try timelock.grantRole(proposerRole, outsider) {}
            catch {
                ghost_directRoleReverts++;
            }
        } else {
            ghost_directRoleAttempts++;
            vm.prank(caller);
            try timelock.revokeRole(proposerRole, proposers[0]) {}
            catch {
                ghost_directRoleReverts++;
            }
        }
    }

    /// Every schedule below the current minDelay must be rejected (INV-2).
    function probeShortDelay(uint256 actorSeed, uint256 delaySeed) external {
        // ghost_minDelay ≥ MIN_NEW_DELAY ≥ 1 day always, so the range is non-empty.
        uint256 delay = bound(delaySeed, 0, ghost_minDelay - 1);
        ghost_shortDelayAttempts++;
        bytes memory data =
            abi.encodeCall(MockTarget.pinch, (PROBE_NONCE_BASE + ghost_shortDelayAttempts));
        bytes32 salt = keccak256(abi.encode("short-delay", ghost_shortDelayAttempts));

        vm.prank(proposers[bound(actorSeed, 0, 1)]);
        try timelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, delay) {}
        catch {
            ghost_shortDelayReverts++;
        }
    }

    /// Done is terminal: re-scheduling or re-executing an executed operation
    /// must revert — no double settlement, ever (INV-5).
    function probeResurrectDone(uint256 actorSeed, uint256 opSeed, uint256 modeSeed) external {
        if (_executed.length == 0) {
            ghost_noopCalls++;
            return;
        }
        GhostOp storage op = _ops[_executed[bound(opSeed, 0, _executed.length - 1)]];

        if (bound(modeSeed, 0, 1) == 0) {
            ghost_resurrectScheduleAttempts++;
            vm.prank(proposers[bound(actorSeed, 0, 1)]);
            try timelock.schedule(
                op.opTarget, op.value, op.data, bytes32(0), op.salt, ghost_minDelay
            ) {}
            catch {
                ghost_resurrectScheduleReverts++;
            }
        } else {
            ghost_resurrectExecuteAttempts++;
            vm.prank(executors[bound(actorSeed, 0, 1)]);
            try timelock.execute(op.opTarget, op.value, op.data, bytes32(0), op.salt) {}
            catch {
                ghost_resurrectExecuteReverts++;
            }
        }
    }

    // ─────────────────────────── ghost views ───────────────────────────

    function opCount() external view returns (uint256) {
        return _ops.length;
    }

    function getOp(uint256 nonce) external view returns (GhostOp memory) {
        return _ops[nonce];
    }

    function trackedRoles() external view returns (bytes32[] memory) {
        return _trackedRoles;
    }

    function trackedAccounts() external view returns (address[] memory) {
        return _trackedAccounts;
    }

    // ─────────────────────────── internals ───────────────────────────

    function _scheduleNew(GhostOp memory op, uint256 actorSeed, uint256 delaySeed) internal {
        uint256 nonce = _ops.length;
        uint256 delay = bound(delaySeed, ghost_minDelay, ghost_minDelay + MAX_EXTRA_DELAY);
        op.salt = bytes32(nonce); // unique per nonce ⇒ unique id even for repeated payloads
        // Ghost id mirrors the v5.6.1 hashOperation encoding; the cross-check
        // against the SUT guards the mirror itself from drifting.
        op.id = keccak256(abi.encode(op.opTarget, op.value, op.data, bytes32(0), op.salt));
        if (op.id != timelock.hashOperation(op.opTarget, op.value, op.data, bytes32(0), op.salt)) {
            ghost_idMismatches++;
        }

        vm.prank(proposers[bound(actorSeed, 0, 1)]);
        try timelock.schedule(op.opTarget, op.value, op.data, bytes32(0), op.salt, delay) {
            op.status = GhostStatus.Pending;
            op.scheduledAt = block.timestamp;
            op.delayUsed = delay;
            op.readyAt = block.timestamp + delay + (_lever("INV-1") ? LEVER_EARLY_MARGIN : 0);
            op.minDelayAtSchedule = ghost_minDelay + (_lever("INV-2") ? 1 : 0);
            _ops.push(op);
            _pendingAdd(nonce);
            ghost_scheduleCount++;
        } catch {
            ghost_scheduleFailures++;
        }
    }

    function _applyExecuteEffects(uint256 nonce, GhostOp storage op) internal {
        ghost_executedCount++;
        if (!_lever("INV-5")) {
            op.status = GhostStatus.Executed;
            op.executedAt = block.timestamp;
            _pendingRemove(nonce);
            _executed.push(nonce);
        }
        if (op.kind == OpKind.Pinch) {
            if (!_lever("INV-8")) ghost_outflow += op.value;
        } else if (op.kind == OpKind.DelayUpdate) {
            if (!_lever("INV-6")) ghost_minDelay = op.newDelayArg;
        } else {
            if (!_lever("INV-7")) {
                ghostRole[op.roleArg][op.accountArg] = (op.kind == OpKind.RoleGrant);
            }
        }
    }

    function _markCancelled(uint256 nonce) internal {
        _ops[nonce].status = GhostStatus.Cancelled;
        _pendingRemove(nonce);
        _cancelledAdd(nonce);
    }

    function _pendingAdd(uint256 nonce) internal {
        _pending.push(nonce);
        _pendingPos[nonce] = _pending.length;
    }

    function _pendingRemove(uint256 nonce) internal {
        uint256 pos = _pendingPos[nonce];
        require(pos != 0, "not pending");
        uint256 last = _pending[_pending.length - 1];
        _pending[pos - 1] = last;
        _pendingPos[last] = pos;
        _pending.pop();
        _pendingPos[nonce] = 0;
    }

    function _cancelledAdd(uint256 nonce) internal {
        _cancelled.push(nonce);
        _cancelledPos[nonce] = _cancelled.length;
    }

    function _cancelledRemove(uint256 nonce) internal {
        uint256 pos = _cancelledPos[nonce];
        require(pos != 0, "not cancelled");
        uint256 last = _cancelled[_cancelled.length - 1];
        _cancelled[pos - 1] = last;
        _cancelledPos[last] = pos;
        _cancelled.pop();
        _cancelledPos[nonce] = 0;
    }

    function _lever(string memory id) internal view returns (bool) {
        return keccak256(bytes(id)) == _falsify;
    }
}
