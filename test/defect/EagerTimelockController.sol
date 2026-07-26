// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice DELIBERATELY DEFECTIVE — TEST FIXTURE ONLY. Never deploy.
///
/// The one permitted buggy SUT variant (CLAUDE.md hard limit 1, docs/PLAN.md
/// §3): a ~10-line subclass overriding the designed `public view virtual`
/// extension hook that ALL readiness checks route through
/// (getOperationState → getTimestamp → every isOperation* / _beforeCall).
///
/// Plausible cover story: "ops asked for a grace window so executors can batch
/// transactions ahead of the exact readiness second."
///
/// The bug is quiet by construction: Unset/Done sentinels preserved, every
/// role check intact, schedule/cancel bookkeeping untouched. Its only effect
/// is that operations read Ready — and execute — up to 15 minutes before the
/// delay the proposer paid for has elapsed. Exactly the kind of subclass bug
/// example-based tests miss and the seeded invariant campaign catches as a
/// shrunk schedule → warp → execute sequence (INV-1; the state-machine
/// comparison INV-5 sees the same lie).
contract EagerTimelockController is TimelockController {
    uint256 private constant _OPS_GRACE = 15 minutes;

    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}

    function getTimestamp(bytes32 id) public view override returns (uint256) {
        uint256 ts = super.getTimestamp(id);
        if (ts <= DONE_TIMESTAMP) return ts; // preserve Unset(0)/Done(1) sentinels
        // Strictly above the grace + Done margin so no Waiting value can ever
        // collapse onto a sentinel (unreachable under suite delays, but exact).
        return ts > _OPS_GRACE + DONE_TIMESTAMP ? ts - _OPS_GRACE : DONE_TIMESTAMP + 1;
    }
}
