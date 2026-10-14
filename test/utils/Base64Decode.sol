// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Test-side base64 decoder (standard alphabet, '=' padding).
library Base64Decode {
    function decode(bytes memory input) internal pure returns (bytes memory out) {
        uint256 len = input.length;
        require(len % 4 == 0, "b64 length");
        if (len == 0) return out;
        uint256 outLen = (len / 4) * 3;
        if (input[len - 1] == "=") outLen--;
        if (input[len - 2] == "=") outLen--;
        out = new bytes(outLen);
        assembly ("memory-safe") {
            let inPtr := add(input, 32)
            let outPtr := add(out, 32)
            let end := add(inPtr, len)
            for {} lt(inPtr, end) {} {
                let w := mload(inPtr)
                let a := val(byte(0, w))
                let b := val(byte(1, w))
                let c := val(byte(2, w))
                let d := val(byte(3, w))
                let v := or(or(shl(18, a), shl(12, b)), or(shl(6, c), d))
                mstore8(outPtr, shr(16, v))
                mstore8(add(outPtr, 1), and(shr(8, v), 0xff))
                mstore8(add(outPtr, 2), and(v, 0xff))
                inPtr := add(inPtr, 4)
                outPtr := add(outPtr, 3)
            }
            function val(ch) -> r {
                switch 1
                case 1 {
                    if and(iszero(lt(ch, 0x41)), iszero(gt(ch, 0x5a))) {
                        r := sub(ch, 0x41)
                        leave
                    }
                    if and(iszero(lt(ch, 0x61)), iszero(gt(ch, 0x7a))) {
                        r := add(sub(ch, 0x61), 26)
                        leave
                    }
                    if and(iszero(lt(ch, 0x30)), iszero(gt(ch, 0x39))) {
                        r := add(sub(ch, 0x30), 52)
                        leave
                    }
                    if eq(ch, 0x2b) {
                        r := 62
                        leave
                    }
                    if eq(ch, 0x2f) {
                        r := 63
                        leave
                    }
                    r := 0 // '='
                }
            }
        }
    }

    function slice(bytes memory b, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        out = new bytes(end - start);
        assembly ("memory-safe") {
            mcopy(add(out, 32), add(add(b, 32), start), sub(end, start))
        }
    }

    /// @dev Index of the first occurrence of `needle` in `hay` at or after `from`; reverts if absent.
    function indexOf(bytes memory hay, bytes memory needle, uint256 from) internal pure returns (uint256) {
        bytes32 h = keccak256(needle);
        uint256 n = needle.length;
        for (uint256 i = from; i + n <= hay.length; ++i) {
            if (hay[i] == needle[0] && keccak256(slice(hay, i, i + n)) == h) return i;
        }
        revert("not found");
    }
}
