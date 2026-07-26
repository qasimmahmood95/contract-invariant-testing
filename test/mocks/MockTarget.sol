// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Test fixture (not production code): the target every scheduled MockTarget
/// operation calls into. It records each call with its arrival timestamp and
/// attached value — the SUT-independent ground truth for "did anything execute
/// early" (INV-1) and "did a cancelled operation land anyway" (INV-3).
///
/// The `nonce` argument is the handler's ghost-operation key, baked into the
/// operation's calldata at schedule time, so every record maps back to exactly
/// one ghost operation without consulting the SUT.
contract MockTarget {
    struct CallRecord {
        uint256 nonce;
        uint256 value;
        uint256 timestamp;
    }

    CallRecord[] private _records;
    mapping(uint256 nonce => uint256) public callCountByNonce;

    function pinch(uint256 nonce) external payable {
        _records.push(CallRecord({nonce: nonce, value: msg.value, timestamp: block.timestamp}));
        callCountByNonce[nonce]++;
    }

    /// Always-reverting payload for the batch-atomicity fuzz test (FZ-6).
    /// Payable so a value-carrying call still reaches the revert string
    /// instead of bouncing on msg.value with empty returndata.
    function fail() external payable {
        revert("MockTarget: deliberate failure");
    }

    function recordCount() external view returns (uint256) {
        return _records.length;
    }

    function record(uint256 i)
        external
        view
        returns (uint256 nonce, uint256 value, uint256 timestamp)
    {
        CallRecord storage r = _records[i];
        return (r.nonce, r.value, r.timestamp);
    }
}
