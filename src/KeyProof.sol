// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Checks that a wrapped key doesn't open its piece, so a seller who sends a fake key can be caught and
/// penalised with no one to trust. The format is version 2 of site/sealcrypto.js, on secp256k1:
///   viewing key  B.x (B lifted with an even y);  wrapped key  0x02 ‖ E.x ‖ K XOR keccak256(DOMAIN ‖ id ‖ B.x ‖ E.x ‖ S.x)
/// where S = e·B = b·E. The buyer reveals S for this one wrapped key and proves S = b·E for the b behind B
/// (Chaum-Pedersen: A1 = w·G, A2 = w·E, c = keccak256(... ‖ A1 ‖ A2) mod n, z = w + c·b; X = c·S as a hint).
/// Scalar multiplications are checked with the ecrecover precompile (it returns the address of u1·G + u2·R for a
/// point R of our choosing), square roots and the one inverse with modexp. Stateless; the pieces call it. A key that
/// opens can never be proven fake: with S proven, the decryption is exact, and it matches the piece's commitment.
/// A seller also proves they made the wrapped key (they know e with E = e·G, see knowsWrap), so nobody can post a key
/// built from someone else's E: a proof of a fake then reveals S = e·B, which only its maker already knew.
contract KeyProof {
    uint256 internal constant P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    struct Proof {
        uint256 sx; // S, the shared point for this wrapped key
        uint256 sy;
        uint256 a1x; // A1 = w·G
        uint256 a1y;
        uint256 a2x; // A2 = w·E
        uint256 a2y;
        uint256 xx; // X = c·S
        uint256 xy;
        uint256 z; // w + c·b mod n
    }

    error BadViewingKey();
    error BadProof();

    /// @notice Whether a registered viewing key can receive version 2 keys (and so be used to prove a fake): the x of
    /// a curve point, below n.
    function isViewingKey(bytes32 viewingKey) public view returns (bool) {
        uint256 x = uint256(viewingKey);
        if (x == 0 || x >= N) return false;
        (bool ok,) = _lift(x);
        return ok;
    }

    /// @notice True when `wrapped` is proven not to open the piece (`pieceId`, key commitment `commitment`) for the
    /// holder of `viewingKey`: malformed (no honest wrapper makes it), or opened with the proven shared point to a key
    /// that doesn't match. False when it opens. Reverts on a proof that doesn't hold. The challenge binds the caller
    /// (the piece), the chain and `buyer`, so a proof can't be replayed elsewhere.
    function isFake(
        bytes calldata wrapped,
        uint256 pieceId,
        bytes32 viewingKey,
        bytes32 commitment,
        address buyer,
        Proof calldata p
    ) external view returns (bool) {
        if (wrapped.length != 65 || wrapped[0] != 0x02) return true;
        uint256 ex = uint256(bytes32(wrapped[1:33]));
        if (ex == 0 || ex >= N) return true;
        (bool okE, uint256 ey) = _lift(ex);
        if (!okE) return true;
        uint256 bx = uint256(viewingKey);
        if (!isViewingKey(viewingKey)) revert BadViewingKey();
        (, uint256 by) = _lift(bx);
        if (!_onCurve(p.sx, p.sy) || !_onCurve(p.a1x, p.a1y) || !_onCurve(p.a2x, p.a2y) || !_onCurve(p.xx, p.xy)) {
            revert BadProof();
        }
        if (p.sx == 0 || p.sx >= N || p.z == 0 || p.z >= N) revert BadProof();
        uint256 c = _challenge(bx, ex, buyer, p);
        if (c == 0) revert BadProof();
        // z·G − c·B = A1, and c·S = X, and z·E = A2 + X: so S = b·E for the b with b·G = B
        if (_lin(p.z, N - c, bx, by) != _addr(p.a1x, p.a1y)) revert BadProof();
        if (_lin(0, c, p.sx, p.sy) != _addr(p.xx, p.xy)) revert BadProof();
        (uint256 yx, uint256 yy) = _add(p.a2x, p.a2y, p.xx, p.xy);
        if (_lin(0, p.z, ex, ey) != _addr(yx, yy)) revert BadProof();
        bytes32 key =
            bytes32(wrapped[33:65]) ^ keccak256(abi.encodePacked("Proof House key wrap v2", pieceId, bx, ex, p.sx));
        return keccak256(abi.encodePacked(key)) != commitment;
    }

    /// @notice Whether the sender of `wrapped` knows the e behind its E (Schnorr: R = r·G, given as its address `r`;
    /// z = r + c·e mod n, c binding the chain, the caller (the piece), the buyer, their viewing key and the whole wrapped
    /// key). False for anything an honest wrapper doesn't make: not 65 bytes, not version 2, E off the curve or ≥ n.
    function knowsWrap(bytes calldata wrapped, bytes32 viewingKey, address buyer, address r, uint256 z)
        external
        view
        returns (bool)
    {
        if (wrapped.length != 65 || wrapped[0] != 0x02 || r == address(0) || z == 0 || z >= N) return false;
        uint256 ex = uint256(bytes32(wrapped[1:33]));
        if (ex == 0 || ex >= N) return false;
        (bool ok, uint256 ey) = _lift(ex);
        if (!ok) return false;
        uint256 c = uint256(
            keccak256(
                abi.encodePacked(
                    "Proof House key wrap v2 proof", block.chainid, msg.sender, buyer, viewingKey, keccak256(wrapped), r
                )
            )
        ) % N;
        // z·G − c·E = R
        return c != 0 && _lin(z, N - c, ex, ey) == r;
    }

    function _challenge(uint256 bx, uint256 ex, address buyer, Proof calldata p) private view returns (uint256) {
        return uint256(
            keccak256(
            abi.encodePacked(
            "Proof House fake key v2", block.chainid, msg.sender, buyer, bx, ex, p.sx, p.sy, p.a1x, p.a1y, p.a2x, p.a2y
        )
        )
        ) % N;
    }

    /// @dev The address of u1·G + u2·R, R = (rx, ry) with 0 < rx < n, u2 ≠ 0: ecrecover returns the address of
    /// r⁻¹(s·R − h·G), so s = u2·r and h = −u1·r give exactly that point. Zero if the precompile refuses.
    function _lin(uint256 u1, uint256 u2, uint256 rx, uint256 ry) private view returns (address) {
        uint256 s = mulmod(u2, rx, N);
        uint256 h = (N - mulmod(u1, rx, N)) % N;
        (bool ok, bytes memory ret) = address(1).staticcall(abi.encode(h, ry & 1 == 0 ? 27 : 28, rx, s));
        if (!ok || ret.length != 32) return address(0);
        address q = abi.decode(ret, (address));
        if (q == address(0)) revert BadProof();
        return q;
    }

    function _addr(uint256 x, uint256 y) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));
    }

    function _onCurve(uint256 x, uint256 y) private pure returns (bool) {
        return x < P && y < P && mulmod(y, y, P) == addmod(mulmod(mulmod(x, x, P), x, P), 7, P);
    }

    /// @dev The point with this x and an even y, if x is on the curve.
    function _lift(uint256 x) private view returns (bool ok, uint256 y) {
        if (x == 0 || x >= P) return (false, 0);
        uint256 c = addmod(mulmod(mulmod(x, x, P), x, P), 7, P);
        y = _modexp(c, (P + 1) / 4);
        ok = mulmod(y, y, P) == c;
        if (y & 1 == 1) y = P - y;
    }

    /// @dev Affine addition of two different points (equal x is refused: a doubling or the point at infinity).
    function _add(uint256 x1, uint256 y1, uint256 x2, uint256 y2) private view returns (uint256 x3, uint256 y3) {
        if (x1 == x2) revert BadProof();
        uint256 lam = mulmod(addmod(y2, P - y1, P), _modexp(addmod(x2, P - x1, P), P - 2), P);
        x3 = addmod(mulmod(lam, lam, P), P - addmod(x1, x2, P), P);
        y3 = addmod(mulmod(lam, addmod(x1, P - x3, P), P), P - y1, P);
    }

    function _modexp(uint256 b, uint256 e) private view returns (uint256 r) {
        (bool ok, bytes memory ret) = address(5).staticcall(abi.encode(uint256(32), uint256(32), uint256(32), b, e, P));
        if (!ok || ret.length != 32) revert BadProof();
        r = abi.decode(ret, (uint256));
    }
}
