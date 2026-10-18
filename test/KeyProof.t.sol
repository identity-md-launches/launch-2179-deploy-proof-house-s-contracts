// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeyProof} from "../src/KeyProof.sol";

/// @dev KeyProof against wrapped keys and proofs made by site/sealcrypto.js (tools/keyproof/fixtures.js): a key that
/// opens is never proven fake; a junk key, a key for someone else, made-up bytes and the old format always are; a
/// proof only holds for its own wrapped key, piece, buyer and chain.
contract KeyProofTest is Test {
    KeyProof internal kp;
    string internal json;
    address internal piece;
    address internal buyer;
    uint256 internal pieceId;
    bytes32 internal vk;
    bytes32 internal commitment;

    function setUp() public {
        kp = new KeyProof();
        json = vm.readFile("test/fixtures/keyproof.json");
        piece = vm.parseJsonAddress(json, ".ctx.piece");
        buyer = vm.parseJsonAddress(json, ".ctx.buyer");
        pieceId = vm.parseJsonUint(json, ".pieceId");
        vk = vm.parseJsonBytes32(json, ".viewingKey");
        commitment = vm.parseJsonBytes32(json, ".commitment");
        vm.chainId(vm.parseJsonUint(json, ".ctx.chainId"));
    }

    function _case(string memory name) internal view returns (bytes memory wrapped, KeyProof.Proof memory p) {
        wrapped = vm.parseJsonBytes(json, string.concat(".", name, ".wrapped"));
        string[] memory a = vm.parseJsonStringArray(json, string.concat(".", name, ".proof"));
        p = KeyProof.Proof(
            vm.parseUint(a[0]), vm.parseUint(a[1]), vm.parseUint(a[2]), vm.parseUint(a[3]), vm.parseUint(a[4]),
            vm.parseUint(a[5]), vm.parseUint(a[6]), vm.parseUint(a[7]), vm.parseUint(a[8])
        );
    }

    function _isFake(bytes memory wrapped, KeyProof.Proof memory p) internal returns (bool) {
        vm.prank(piece);
        return kp.isFake(wrapped, pieceId, vk, commitment, buyer, p);
    }

    function test_aKeyThatOpensIsNeverProvenFake() public {
        (bytes memory w, KeyProof.Proof memory p) = _case("honest");
        assertFalse(_isFake(w, p), "the proof holds, and the key opens: not fake");
    }

    function test_aJunkKeyIsProvenFake() public {
        (bytes memory w, KeyProof.Proof memory p) = _case("junkKey");
        uint256 g = gasleft();
        assertTrue(_isFake(w, p));
        emit log_named_uint("gas to check a fake-key proof", g - gasleft());
    }

    function test_theRightKeyForSomeoneElseIsProvenFake() public {
        (bytes memory w, KeyProof.Proof memory p) = _case("wrongRecipient");
        assertTrue(_isFake(w, p), "it doesn't open for the buyer's registered key");
    }

    function test_madeUpBytesAndTheOldFormatAreFake() public {
        (bytes memory w, KeyProof.Proof memory p) = _case("random");
        assertTrue(_isFake(w, p));
        bytes memory v1 = vm.parseJsonBytes(json, ".v1Shaped.wrapped");
        assertTrue(_isFake(v1, p));
        assertTrue(_isFake(hex"02", p), "too short");
        bytes memory zeroE = new bytes(65);
        zeroE[0] = 0x02;
        assertTrue(_isFake(zeroE, p), "no ephemeral point");
    }

    function test_aProofOnlyHoldsForItsOwnWrappedKey() public {
        (bytes memory honest,) = _case("honest");
        (, KeyProof.Proof memory junkProof) = _case("junkKey");
        vm.prank(piece);
        vm.expectRevert(KeyProof.BadProof.selector);
        kp.isFake(honest, pieceId, vk, commitment, buyer, junkProof); // another key's proof can't frame this one
    }

    function test_aProofOnlyHoldsForItsBuyerPieceAndChain() public {
        (bytes memory w, KeyProof.Proof memory p) = _case("junkKey");
        vm.prank(piece);
        vm.expectRevert(KeyProof.BadProof.selector);
        kp.isFake(w, pieceId, vk, commitment, address(0xBEEF), p);
        vm.prank(address(0xCAFE)); // another piece
        vm.expectRevert(KeyProof.BadProof.selector);
        kp.isFake(w, pieceId, vk, commitment, buyer, p);
        vm.chainId(1);
        vm.prank(piece);
        vm.expectRevert(KeyProof.BadProof.selector);
        kp.isFake(w, pieceId, vk, commitment, buyer, p);
    }

    function test_aTamperedProofFails() public {
        (bytes memory w, KeyProof.Proof memory p) = _case("junkKey");
        KeyProof.Proof memory q = p;
        q.z = p.z == 1 ? 2 : p.z - 1;
        vm.prank(piece);
        vm.expectRevert(KeyProof.BadProof.selector);
        kp.isFake(w, pieceId, vk, commitment, buyer, q);
        // another shared point (G itself), with the rest unchanged
        q = p;
        q.sx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
        q.sy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
        vm.prank(piece);
        vm.expectRevert(KeyProof.BadProof.selector);
        kp.isFake(w, pieceId, vk, commitment, buyer, q);
        // a point off the curve
        q = p;
        q.a1y = p.a1y ^ 1;
        vm.prank(piece);
        vm.expectRevert(KeyProof.BadProof.selector);
        kp.isFake(w, pieceId, vk, commitment, buyer, q);
        // the honest key with its proof, but claiming the buyer's key is another one
        (bytes memory honest, KeyProof.Proof memory hp) = _case("honest");
        vm.prank(piece);
        vm.expectRevert();
        kp.isFake(honest, pieceId, bytes32(uint256(vk) ^ 2), commitment, buyer, hp);
    }

    function test_viewingKeys() public view {
        assertTrue(kp.isViewingKey(vk));
        assertFalse(kp.isViewingKey(bytes32(0)));
        assertFalse(kp.isViewingKey(bytes32(type(uint256).max)), "x above n");
        assertFalse(kp.isViewingKey(bytes32(uint256(5))), "x = 5 is not on secp256k1");
    }
}
