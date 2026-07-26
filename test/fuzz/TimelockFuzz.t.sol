// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockTarget} from "../mocks/MockTarget.sol";

/// M3 targeted fuzz suite (docs/PLAN.md §2, FZ-1…FZ-6): example-shaped edges
/// that complement the stateful campaign — exact revert selectors, exact
/// boundary seconds, exact atomicity — over the same self-administered
/// deployment config (ADR-0001). Fuzzed inputs are bounded by the named
/// constants below; each test documents its FALSIFY=FZ-<n> lever, a harness
/// perturbation proven to turn exactly that test red (CLAUDE.md hard limit 3).
contract TimelockFuzzTest is Test {
    uint256 internal constant MIN_DELAY = 2 days;
    uint256 internal constant MAX_EXTRA_DELAY = 7 days; // delay ∈ [minDelay, minDelay + this]
    uint256 internal constant MAX_OP_VALUE = 10 ether;
    uint256 internal constant TREASURY = 1_000 ether; // ≥ MAX_BATCH * MAX_OP_VALUE
    uint256 internal constant MAX_POST_READY_DRIFT = 30 days; // FZ-4 "at any warp" bound
    uint256 internal constant MAX_BATCH = 8; // ≥ 2 so mismatch and atomicity are meaningful

    TimelockController internal timelock;
    MockTarget internal mockTarget;

    address internal proposer1;
    address internal proposer2;
    address internal executor1;
    address internal executor2;
    address internal outsider;

    bytes32 private _falsify;

    function setUp() public {
        proposer1 = makeAddr("proposer1");
        proposer2 = makeAddr("proposer2");
        executor1 = makeAddr("executor1");
        executor2 = makeAddr("executor2");
        outsider = makeAddr("outsider");

        address[] memory proposers = new address[](2);
        proposers[0] = proposer1;
        proposers[1] = proposer2;
        address[] memory executors = new address[](2);
        executors[0] = executor1;
        executors[1] = executor2;

        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));
        mockTarget = new MockTarget();
        // No conservation ghost in this suite (that is INV-8's job), so the
        // treasury can be dealt directly.
        vm.deal(address(timelock), TREASURY);

        _falsify = keccak256(bytes(vm.envOr("FALSIFY", string(""))));
    }

    /// FZ-1 boundary precision.
    /// Property: execute at readyAt − 1s reverts with
    ///           TimelockUnexpectedOperationState(id, Ready-bitmap); execute at
    ///           exactly readyAt succeeds and the payload lands at exactly that
    ///           second — for every lawful delay and value.
    /// Custody risk: the readiness second is the delay promise's edge; an
    ///           off-by-one here is a shorter veto window than policy states
    ///           (the on-chain sibling of reconciliation-testing's 2^53+1
    ///           boundary property).
    /// Falsification lever: FALSIFY=FZ-1 treats readyAt − 1s as the boundary,
    ///           so the must-succeed leg executes one second early and goes red.
    function testFuzz_FZ1_boundaryPrecision(uint256 delaySeed, uint256 valueSeed) public {
        uint256 delay = bound(delaySeed, MIN_DELAY, MIN_DELAY + MAX_EXTRA_DELAY);
        uint256 value = bound(valueSeed, 0, MAX_OP_VALUE);
        bytes memory data = abi.encodeCall(MockTarget.pinch, (1));
        bytes32 salt = "FZ-1";
        bytes32 id = timelock.hashOperation(address(mockTarget), value, data, bytes32(0), salt);

        vm.prank(proposer1);
        timelock.schedule(address(mockTarget), value, data, bytes32(0), salt, delay);
        uint256 readyAt = block.timestamp + delay;
        if (_lever("FZ-1")) readyAt -= 1;

        vm.warp(readyAt - 1);
        vm.prank(executor1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, id, _readyBitmap()
            )
        );
        timelock.execute(address(mockTarget), value, data, bytes32(0), salt);

        vm.warp(readyAt);
        vm.prank(executor1);
        timelock.execute(address(mockTarget), value, data, bytes32(0), salt);

        (, uint256 recValue, uint256 recAt) = mockTarget.record(0);
        assertEq(recAt, readyAt, "FZ-1: payload landed at exactly readyAt");
        assertEq(recValue, value, "FZ-1: full value carried");
        assertTrue(timelock.isOperationDone(id), "FZ-1: Done after boundary execute");
    }

    /// FZ-2 minimum-delay floor.
    /// Property: schedule with any delay < minDelay reverts with
    ///           TimelockInsufficientDelay(delay, minDelay), for every proposer.
    /// Custody risk: one accepted under-delay silently shrinks the veto window
    ///           below policy for that operation.
    /// Falsification lever: FALSIFY=FZ-2 submits a lawful delay (== minDelay)
    ///           while still expecting the revert.
    function testFuzz_FZ2_shortDelayReverts(uint256 delaySeed, uint256 proposerSeed) public {
        uint256 delay = bound(delaySeed, 0, MIN_DELAY - 1);
        if (_lever("FZ-2")) delay = MIN_DELAY;
        address proposer = bound(proposerSeed, 0, 1) == 0 ? proposer1 : proposer2;
        bytes memory data = abi.encodeCall(MockTarget.pinch, (2));

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockInsufficientDelay.selector, delay, MIN_DELAY
            )
        );
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), "FZ-2", delay);
    }

    /// FZ-3 id identity.
    /// Property: re-scheduling an id that is pending — or Done — reverts with
    ///           TimelockUnexpectedOperationState(id, Unset-bitmap); changing
    ///           only the salt yields a fresh id whose lifecycle is fully
    ///           independent of the original.
    /// Custody risk: id collision or resurrection is double settlement; salt
    ///           independence is what lets identical payloads be scheduled
    ///           twice on purpose without aliasing.
    /// Falsification lever: FALSIFY=FZ-3 swaps a fresh salt into the
    ///           must-revert re-schedule, which then quietly succeeds.
    function testFuzz_FZ3_rescheduleAndSaltIdentity(uint256 delaySeed, bytes32 saltA) public {
        uint256 delay = bound(delaySeed, MIN_DELAY, MIN_DELAY + MAX_EXTRA_DELAY);
        bytes memory data = abi.encodeCall(MockTarget.pinch, (3));
        bytes32 idA = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), saltA);

        vm.prank(proposer1);
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), saltA, delay);

        // While pending: the same id cannot be scheduled again.
        bytes32 saltRetry = _lever("FZ-3") ? keccak256(abi.encode(saltA)) : saltA;
        bytes32 idRetry =
            timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), saltRetry);
        vm.prank(proposer2);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                idRetry,
                _unsetBitmap()
            )
        );
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), saltRetry, delay);

        // After Done: still no re-schedule, ever.
        vm.warp(block.timestamp + delay);
        vm.prank(executor1);
        timelock.execute(address(mockTarget), 0, data, bytes32(0), saltA);
        vm.prank(proposer1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, idA, _unsetBitmap()
            )
        );
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), saltA, delay);

        // Salt-only change: fresh, independent id.
        bytes32 saltB = keccak256(abi.encodePacked(saltA, "independent"));
        bytes32 idB = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), saltB);
        assertTrue(idB != idA, "FZ-3: salt change produces a fresh id");
        vm.prank(proposer1);
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), saltB, delay);
        assertTrue(timelock.isOperationPending(idB), "FZ-3: fresh id waits independently");
        assertTrue(timelock.isOperationDone(idA), "FZ-3: original id stays Done");
    }

    /// FZ-4 predecessor gating.
    /// Property: an operation whose predecessor is not Done reverts with
    ///           TimelockUnexecutedPredecessor(predId) at every warp past its
    ///           own readiness; once the predecessor executes, it goes through.
    /// Custody risk: ordering dependencies encode "settle A before B" — a
    ///           gate bypass reorders settlement no matter how long you wait.
    /// Falsification lever: FALSIFY=FZ-4 executes the predecessor first and
    ///           still expects the dependent to be gated.
    function testFuzz_FZ4_unexecutedPredecessorGates(uint256 delaySeed, uint256 warpSeed) public {
        uint256 delay = bound(delaySeed, MIN_DELAY, MIN_DELAY + MAX_EXTRA_DELAY);
        bytes memory predData = abi.encodeCall(MockTarget.pinch, (40));
        bytes memory depData = abi.encodeCall(MockTarget.pinch, (41));
        bytes32 predId =
            timelock.hashOperation(address(mockTarget), 0, predData, bytes32(0), "FZ-4-pred");

        vm.prank(proposer1);
        timelock.schedule(address(mockTarget), 0, predData, bytes32(0), "FZ-4-pred", delay);
        vm.prank(proposer1);
        timelock.schedule(address(mockTarget), 0, depData, predId, "FZ-4-dep", delay);

        // Any warp at or past the dependent's own readiness: still gated.
        uint256 readyAt = block.timestamp + delay;
        vm.warp(bound(warpSeed, readyAt, readyAt + MAX_POST_READY_DRIFT));

        if (_lever("FZ-4")) {
            vm.prank(executor1);
            timelock.execute(address(mockTarget), 0, predData, bytes32(0), "FZ-4-pred");
        }
        vm.prank(executor1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexecutedPredecessor.selector, predId
            )
        );
        timelock.execute(address(mockTarget), 0, depData, predId, "FZ-4-dep");

        // Positive control: Done predecessor opens the gate.
        vm.prank(executor2);
        timelock.execute(address(mockTarget), 0, predData, bytes32(0), "FZ-4-pred");
        vm.prank(executor1);
        timelock.execute(address(mockTarget), 0, depData, predId, "FZ-4-dep");
        assertEq(mockTarget.callCountByNonce(41), 1, "FZ-4: dependent landed exactly once");
    }

    /// FZ-5 caller matrix.
    /// Property: for a random (actor, action) pair over
    ///           {schedule, cancel, execute, updateDelay, grantRole}, the call
    ///           succeeds iff the actor holds the matching role — and
    ///           updateDelay/grantRole succeed for no external actor at all
    ///           (self-administration; the timelock-as-caller positive leg is
    ///           pinned by the deploy smoke and wiring tests).
    /// Custody risk: maker/checker separation of duties; one quiet success off
    ///           the matrix is a rogue single-key actor.
    /// Falsification lever: FALSIFY=FZ-5 claims the outsider may schedule, so
    ///           the outsider's rejected schedule reads as a wrong revert.
    function testFuzz_FZ5_callerMatrix(uint256 actorSeed, uint256 actionSeed, uint256 delaySeed)
        public
    {
        address[5] memory actors = [proposer1, proposer2, executor1, executor2, outsider];
        uint256 a = bound(actorSeed, 0, 4);
        address actor = actors[a];
        uint256 action = bound(actionSeed, 0, 4);
        uint256 delay = bound(delaySeed, MIN_DELAY, MIN_DELAY + MAX_EXTRA_DELAY);

        bool isProposer = a < 2;
        bool isCanceller = a < 2; // constructor wiring: proposers are cancellers
        bool isExecutor = a == 2 || a == 3;
        if (_lever("FZ-5")) isProposer = isProposer || actor == outsider;

        bytes memory data = abi.encodeCall(MockTarget.pinch, (5));

        if (action == 0) {
            // schedule ⇒ PROPOSER_ROLE
            vm.prank(actor);
            try timelock.schedule(address(mockTarget), 0, data, bytes32(0), "FZ-5-s", delay) {
                assertTrue(isProposer, "FZ-5: non-proposer scheduled");
            } catch {
                assertFalse(isProposer, "FZ-5: proposer rejected from schedule");
            }
        } else if (action == 1) {
            // cancel ⇒ CANCELLER_ROLE
            bytes32 id = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), "FZ-5-c");
            vm.prank(proposer1);
            timelock.schedule(address(mockTarget), 0, data, bytes32(0), "FZ-5-c", delay);
            vm.prank(actor);
            try timelock.cancel(id) {
                assertTrue(isCanceller, "FZ-5: non-canceller cancelled");
            } catch {
                assertFalse(isCanceller, "FZ-5: canceller rejected from cancel");
            }
        } else if (action == 2) {
            // execute ⇒ EXECUTOR_ROLE (readiness satisfied so only the role gates)
            vm.prank(proposer1);
            timelock.schedule(address(mockTarget), 0, data, bytes32(0), "FZ-5-e", delay);
            vm.warp(block.timestamp + delay);
            vm.prank(actor);
            try timelock.execute(address(mockTarget), 0, data, bytes32(0), "FZ-5-e") {
                assertTrue(isExecutor, "FZ-5: non-executor executed");
            } catch {
                assertFalse(isExecutor, "FZ-5: executor rejected from execute");
            }
        } else if (action == 3) {
            // updateDelay ⇒ timelock itself only — no external actor ever
            vm.prank(actor);
            try timelock.updateDelay(3 days) {
                assertTrue(false, "FZ-5: external caller updated minDelay");
            } catch {}
        } else {
            // grantRole ⇒ DEFAULT_ADMIN_ROLE, held only by the timelock
            bytes32 proposerRole = timelock.PROPOSER_ROLE();
            vm.prank(actor);
            try timelock.grantRole(proposerRole, actor) {
                assertTrue(false, "FZ-5: external caller granted a role");
            } catch {}
        }
    }

    /// FZ-6 batch atomicity.
    /// Property: a length-mismatched scheduleBatch reverts with
    ///           TimelockInvalidOperationLength; one failing inner call
    ///           reverts the whole executeBatch (bubbled reason), leaves zero
    ///           partial effects (no calls landed, no value moved, batch still
    ///           Ready); an all-good batch of the same shape executes fully.
    /// Custody risk: partial settlement of a multi-leg operation is exactly
    ///           the half-executed transfer batch reconciliation exists to
    ///           catch off-chain.
    /// Falsification lever: FALSIFY=FZ-6 removes the failing call while still
    ///           expecting the atomic revert.
    function testFuzz_FZ6_batchAtomicity(
        uint256 nSeed,
        uint256 failIdxSeed,
        uint256 delaySeed,
        uint256 valueSeed
    ) public {
        uint256 n = bound(nSeed, 2, MAX_BATCH);
        uint256 failIdx = bound(failIdxSeed, 0, n - 1);
        uint256 delay = bound(delaySeed, MIN_DELAY, MIN_DELAY + MAX_EXTRA_DELAY);
        uint256 value = bound(valueSeed, 0, MAX_OP_VALUE);

        address[] memory targets = new address[](n);
        uint256[] memory values = new uint256[](n);
        bytes[] memory payloads = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            targets[i] = address(mockTarget);
            values[i] = value;
            payloads[i] = abi.encodeCall(MockTarget.pinch, (60 + i));
        }

        // Length mismatch (payloads one short) is rejected outright.
        bytes[] memory shortPayloads = new bytes[](n - 1);
        for (uint256 i = 0; i < n - 1; i++) {
            shortPayloads[i] = payloads[i];
        }
        vm.prank(proposer1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockInvalidOperationLength.selector, n, n - 1, n
            )
        );
        timelock.scheduleBatch(targets, values, shortPayloads, bytes32(0), "FZ-6-mismatch", delay);

        // One failing leg reverts the whole batch — atomically.
        if (!_lever("FZ-6")) {
            payloads[failIdx] = abi.encodeCall(MockTarget.fail, ());
        }
        bytes32 batchId =
            timelock.hashOperationBatch(targets, values, payloads, bytes32(0), "FZ-6-fail");
        vm.prank(proposer1);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), "FZ-6-fail", delay);
        vm.warp(block.timestamp + delay);

        uint256 treasuryBefore = address(timelock).balance;
        vm.prank(executor1);
        vm.expectRevert("MockTarget: deliberate failure");
        timelock.executeBatch(targets, values, payloads, bytes32(0), "FZ-6-fail");

        assertEq(mockTarget.recordCount(), 0, "FZ-6: no partial legs landed");
        assertEq(address(mockTarget).balance, 0, "FZ-6: no partial value moved");
        assertEq(address(timelock).balance, treasuryBefore, "FZ-6: treasury untouched");
        assertTrue(timelock.isOperationReady(batchId), "FZ-6: failed batch stays Ready, not Done");

        // Positive control: the same shape without the failing leg settles fully.
        for (uint256 i = 0; i < n; i++) {
            payloads[i] = abi.encodeCall(MockTarget.pinch, (80 + i));
        }
        bytes32 goodId =
            timelock.hashOperationBatch(targets, values, payloads, bytes32(0), "FZ-6-good");
        vm.prank(proposer2);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), "FZ-6-good", delay);
        vm.warp(block.timestamp + delay);
        vm.prank(executor2);
        timelock.executeBatch(targets, values, payloads, bytes32(0), "FZ-6-good");

        assertEq(mockTarget.recordCount(), n, "FZ-6: every leg landed");
        assertEq(address(mockTarget).balance, n * value, "FZ-6: full value settled");
        assertTrue(timelock.isOperationDone(goodId), "FZ-6: good batch Done");
    }

    function _readyBitmap() internal pure returns (bytes32) {
        return bytes32(1 << uint8(TimelockController.OperationState.Ready));
    }

    function _unsetBitmap() internal pure returns (bytes32) {
        return bytes32(1 << uint8(TimelockController.OperationState.Unset));
    }

    function _lever(string memory id) internal view returns (bool) {
        return keccak256(bytes(id)) == _falsify;
    }
}
