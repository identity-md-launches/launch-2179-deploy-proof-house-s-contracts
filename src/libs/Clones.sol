// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice EIP-1167 minimal proxy deployment.
library Clones {
    error CloneFailed();

    function clone(address implementation) internal returns (address instance) {
        assembly ("memory-safe") {
            mstore(0x00, or(shr(0xe8, shl(0x60, implementation)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            mstore(0x20, or(shl(0x78, implementation), 0x5af43d82803e903d91602b57fd5bf3))
            instance := create(0, 0x09, 0x37)
        }
        if (instance == address(0)) revert CloneFailed();
    }

    /// @notice Deploys a full, independent copy of `implementation`'s runtime code (no proxy, no DELEGATECALL).
    /// The init code is: PUSH20 impl, EXTCODESIZE, DUP1, PUSH0, PUSH0, PUSH20 impl, EXTCODECOPY, PUSH0, RETURN.
    /// Used for THE SOURCE, whose 1.8 MB revealed tokenURI must be returned without a proxy copying it again.
    function copyCode(address implementation) internal returns (address instance) {
        bytes memory initCode = abi.encodePacked(hex"73", implementation, hex"3b805f5f73", implementation, hex"3c5ff3");
        assembly ("memory-safe") {
            instance := create(0, add(initCode, 32), mload(initCode))
        }
        if (instance == address(0) || instance.code.length == 0) revert CloneFailed();
    }
}
