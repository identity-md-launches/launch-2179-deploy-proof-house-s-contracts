// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Stores bytes as the runtime code of a tiny contract (prefixed with STOP so it can never run).
library SSTORE2 {
    error WriteFailed();
    error TooLarge();

    uint256 internal constant MAX = 24_575;

    function write(bytes memory data) internal returns (address pointer) {
        if (data.length > MAX) revert TooLarge();
        // creation code: PUSH2 len+1, DUP1, PUSH1 0x0a, RETURNDATASIZE, CODECOPY, RETURNDATASIZE, RETURN, then 0x00 + data
        bytes memory code = abi.encodePacked(hex"61", uint16(data.length + 1), hex"80600a3d393df300", data);
        assembly ("memory-safe") {
            pointer := create(0, add(code, 32), mload(code))
        }
        if (pointer == address(0)) revert WriteFailed();
    }

    function size(address pointer) internal view returns (uint256) {
        uint256 s = pointer.code.length;
        return s == 0 ? 0 : s - 1;
    }

    function read(address pointer) internal view returns (bytes memory data) {
        uint256 len = size(pointer);
        data = new bytes(len);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 32), 1, len)
        }
    }

    /// @dev Copies the stored bytes to memory at `dest` (raw pointer). Returns the number of bytes copied.
    function copyTo(address pointer, uint256 dest) internal view returns (uint256 len) {
        len = size(pointer);
        assembly ("memory-safe") {
            extcodecopy(pointer, dest, 1, len)
        }
    }
}
