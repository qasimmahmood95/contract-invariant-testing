// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// M1 smoke test.
/// Property: the pinned SUT deploys hermetically (no fork, no RPC) with exactly
///           the role wiring the suite assumes (ADR-0001), and a full
///           schedule -> warp -> execute lifecycle works, including the readiness
///           boundary: execution succeeds at exactly readyAt and not one second
///           before.
/// Custody risk: none asserted directly — this test is the hermeticity proof the
///           invariant campaign (M2) builds on. The boundary is fuzzed properly
///           in FZ-1 (M3).
/// Falsification lever: perturb MIN_DELAY or either warp offset by one second —
///           exercised manually at M1; automated levers land with the
///           falsification harness in M4.
contract DeploySmokeTest is Test {
    uint256 internal constant MIN_DELAY = 2 days;
    uint256 internal constant NEW_DELAY = 3 days;

    TimelockController internal timelock;

    address internal proposer1;
    address internal proposer2;
    address internal executor1;
    address internal executor2;
    address internal outsider;

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

        // Self-administered config under test (ADR-0001): no external admin,
        // closed executor role (no address(0) grant).
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));
    }

    function test_deploymentWiring() public view {
        assertEq(timelock.getMinDelay(), MIN_DELAY, "minDelay");

        // The timelock administers itself and nobody else does.
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)), "self admin");
        assertFalse(
            timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)), "deployer is not admin"
        );

        // Proposers hold PROPOSER and (per constructor) CANCELLER; executors hold EXECUTOR.
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer1), "proposer1");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer2), "proposer2");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer1), "canceller1");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer2), "canceller2");
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), executor1), "executor1");
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), executor2), "executor2");

        // Closed executor role: the open-role sentinel address(0) holds nothing.
        assertFalse(
            timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "executor role is closed"
        );
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), outsider), "outsider");
    }

    function test_fullLifecycleSelfAdministration() public {
        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (NEW_DELAY));
        bytes32 id = timelock.hashOperation(address(timelock), 0, data, bytes32(0), bytes32(0));
        uint256 readyAt = block.timestamp + MIN_DELAY;

        vm.prank(proposer1);
        timelock.schedule(address(timelock), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        assertEq(timelock.getTimestamp(id), readyAt, "readyAt recorded");

        // One second early: still Waiting, execution must revert.
        vm.warp(readyAt - 1);
        vm.prank(executor1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready))
            )
        );
        timelock.execute(address(timelock), 0, data, bytes32(0), bytes32(0));

        // At exactly readyAt: Ready, execution succeeds and the timelock has
        // reconfigured itself — the only lawful way minDelay ever changes.
        vm.warp(readyAt);
        vm.prank(executor1);
        timelock.execute(address(timelock), 0, data, bytes32(0), bytes32(0));

        assertEq(timelock.getMinDelay(), NEW_DELAY, "delay updated via self-call");
        assertTrue(timelock.isOperationDone(id), "operation done");
    }
}
