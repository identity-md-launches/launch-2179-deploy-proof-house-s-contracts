// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {TwoStepOwnable} from "../src/base/TwoStepOwnable.sol";
import {Base64Decode} from "./utils/Base64Decode.sol";

contract ArtifactsSourceTest is Fixture {
    uint256 internal constant CHUNK = 24_000;
    /// @dev What the revealed tokenURI must fit in, so public RPCs can serve it to marketplaces.
    uint256 internal constant TOKENURI_GAS_CAP = 14_000_000;

    /// @dev Stores the reference payload encrypted with the test key, as the ceremony's output would be stored.
    function _storePayload() internal returns (bytes memory payload, bytes memory sealedPayload) {
        payload = bytes(vm.readFile("reference/the-source.payload.b64"));
        sealedPayload = _sourceCipher(payload, SOURCE_KEY);
        vm.startPrank(curator);
        for (uint256 off; off < sealedPayload.length; off += CHUNK) {
            uint256 end = off + CHUNK > sealedPayload.length ? sealedPayload.length : off + CHUNK;
            source.storePayloadChunk(Base64Decode.slice(sealedPayload, off, end));
        }
        source.lockPayload(SOURCE_COMMITMENT);
        vm.stopPrank();
    }

    function _runAuction() internal returns (ArtifactsPiece piece) {
        vm.prank(curator);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 days));
        vm.prank(alice);
        source.bid{value: 1 ether}(address(0));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        piece = ArtifactsPiece(source.settle());
    }

    function test_auctionNeedsLockedPayload() public {
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.NotLocked.selector);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 days));
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        source.storePayloadChunk("x");
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsSource.EmptyPayload.selector);
        source.lockPayload(SOURCE_COMMITMENT);
        source.storePayloadChunk("abc");
        vm.expectRevert(ArtifactsSource.NoCommitment.selector);
        source.lockPayload(bytes32(0));
        source.resetPayload();
        source.storePayloadChunk("abcd");
        source.lockPayload(SOURCE_COMMITMENT);
        vm.expectRevert(ArtifactsSource.IsLocked.selector);
        source.storePayloadChunk("more");
        vm.expectRevert(ArtifactsSource.IsLocked.selector);
        source.resetPayload();
        vm.stopPrank();
        assertEq(source.payloadHash(), keccak256("abcd"));
        assertEq(source.payloadSize(), 4);
        assertEq(source.keyCommitment(), SOURCE_COMMITMENT);
    }

    /// @dev The 5% raise rounds up, so even dust-sized bids must strictly exceed the high bid.
    function test_tinyBidsMustStrictlyExceed() public {
        vm.startPrank(curator);
        source.storePayloadChunk("x");
        source.lockPayload(SOURCE_COMMITMENT);
        source.setAuction(1, uint64(vm.getBlockTimestamp() + 1 hours));
        vm.stopPrank();
        vm.prank(alice);
        source.bid{value: 19}(address(0));
        vm.prank(bob);
        vm.expectRevert(ArtifactsSource.BidTooLow.selector);
        source.bid{value: 19}(address(0));
        vm.prank(bob);
        source.bid{value: 20}(address(0));
        assertEq(source.highBidder(), bob);
        vm.prank(carol);
        vm.expectRevert(ArtifactsSource.BidTooLow.selector);
        source.bid{value: 20}(address(0));
        vm.prank(carol);
        source.bid{value: 21}(address(0));
        assertEq(source.highBidder(), carol);
        // at 100 wei exactly 5% is required: 104 fails, 105 passes
        vm.prank(alice);
        source.bid{value: 100}(address(0));
        vm.prank(bob);
        vm.expectRevert(ArtifactsSource.BidTooLow.selector);
        source.bid{value: 104}(address(0));
        vm.prank(bob);
        source.bid{value: 105}(address(0));
    }

    function test_auctionRules() public {
        vm.prank(curator);
        source.storePayloadChunk("payload");
        vm.prank(curator);
        source.lockPayload(SOURCE_COMMITMENT);
        vm.prank(alice);
        vm.expectRevert(ArtifactsSource.AuctionNotOpen.selector);
        source.bid{value: 1 ether}(address(0));
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.BadEndTime.selector);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp()));
        uint64 end = uint64(vm.getBlockTimestamp() + 1 hours);
        vm.prank(curator);
        source.setAuction(1 ether, end);
        vm.prank(alice);
        vm.expectRevert(ArtifactsSource.BidTooLow.selector);
        source.bid{value: 0.99 ether}(address(0));
        vm.prank(alice);
        source.bid{value: 1 ether}(broker);
        vm.prank(bob);
        vm.expectRevert(ArtifactsSource.BidTooLow.selector);
        source.bid{value: 1.049 ether}(address(0));
        vm.prank(bob);
        source.bid{value: 1.05 ether}(address(0));
        assertEq(source.refunds(alice), 1 ether);
        assertEq(source.highBidder(), bob);
        // curator cannot reset a live auction
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.AuctionLive.selector);
        source.setAuction(2 ether, end + 1 days);
        // extension in the final 10 minutes
        vm.warp(end - 5 minutes);
        vm.prank(carol);
        source.bid{value: 2 ether}(address(0));
        assertEq(source.endTime(), vm.getBlockTimestamp() + 10 minutes);
        vm.expectRevert(ArtifactsSource.AuctionNotEnded.selector);
        source.settle();
        vm.prank(alice);
        source.withdrawRefund();
        assertEq(alice.balance, 1000 ether);
        vm.prank(alice);
        vm.expectRevert(ArtifactsSource.NothingToWithdraw.selector);
        source.withdrawRefund();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.prank(alice);
        vm.expectRevert(ArtifactsSource.AuctionEnded.selector);
        source.bid{value: 3 ether}(address(0));
        ArtifactsPiece piece = ArtifactsPiece(source.settle());
        assertEq(piece.ownerOf(1), carol);
        assertEq(address(piece).code, address(pieceImpl).code, "THE SOURCE is a full copy of ArtifactsPiece");
        assertEq(piece.name(), unicode"ARTIFACTS · THE SOURCE");
        assertTrue(piece.isSource());
        assertEq(source.pieceContract(), address(piece));
        // proceeds went through the ledger (no broker on the winning bid => house takes the broker share)
        assertEq(house.balances(artist, address(0)), 1.4 ether);
        assertEq(house.balances(address(house), address(0)), 0.6 ether);
        assertEq(address(house).balance, 2 ether);
        assertEq(address(source).balance, 1.05 ether); // bob's refund still pending
        vm.expectRevert(ArtifactsSource.AuctionNotOpen.selector);
        source.settle();
        vm.prank(bob);
        source.withdrawRefund();
        assertEq(address(source).balance, 0);
    }

    function test_auctionReopensWhenNoBids() public {
        vm.prank(curator);
        source.storePayloadChunk("payload");
        vm.prank(curator);
        source.lockPayload(SOURCE_COMMITMENT);
        vm.prank(curator);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 hours));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.expectRevert(ArtifactsSource.NoBids.selector);
        source.settle();
        vm.prank(curator);
        source.setAuction(0.5 ether, uint64(vm.getBlockTimestamp() + 1 hours));
        assertEq(source.reserve(), 0.5 ether);
    }

    function test_storedPayloadIsUnreadableWithoutTheKey() public {
        (bytes memory payload, bytes memory sealedPayload) = _storePayload();
        assertEq(source.payloadHash(), keccak256(sealedPayload));
        assertTrue(keccak256(source.payload()) != keccak256(payload), "stored in the clear");
        // the plaintext's opening ({"name":" in base64) is not what is stored
        assertTrue(keccak256(Base64Decode.slice(source.payload(), 0, 12)) != keccak256("eyJuYW1lIjoi"));
        assertEq(keccak256(Base64Decode.slice(payload, 0, 12)), keccak256("eyJuYW1lIjoi"));
        ArtifactsPiece piece = _runAuction();
        assertEq(piece.commitment(), SOURCE_COMMITMENT, "the piece carries the key commitment");
        assertFalse(piece.revealed());
        assertEq(piece.revealKey(), bytes32(0));
    }

    function test_revealPublishesTheKeyAndDecryptsByteForByte() public {
        (bytes memory payload,) = _storePayload();
        ArtifactsPiece piece = _runAuction();
        // sealed until revealed: the R9 frame
        bytes memory sealedUri = bytes(piece.tokenURI(1));
        bytes memory json = Base64Decode.decode(Base64Decode.slice(sealedUri, 29, sealedUri.length));
        {
            uint256 imgAt = Base64Decode.indexOf(json, bytes("data:image/svg+xml;base64,"), 0) + 26;
            uint256 imgEnd = Base64Decode.indexOf(json, bytes('"}'), imgAt);
            bytes memory sealSvg = Base64Decode.decode(Base64Decode.slice(json, imgAt, imgEnd));
            bytes memory framed = bytes(vm.readFile("reference/framed/framed-MASTER.svg"));
            uint256 frameAt = Base64Decode.indexOf(framed, bytes('<g fill="#1a1a1a"'), 0);
            uint256 dotsAt = Base64Decode.indexOf(framed, bytes("<circle"), 0);
            bytes memory expectedSeal =
                bytes.concat(Base64Decode.slice(framed, 0, dotsAt), Base64Decode.slice(framed, frameAt, framed.length));
            assertEq(sealSvg, expectedSeal, "THE SOURCE seal differs from R9 frame");
        }
        // only the owner, only with the committed key, only once
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.NotTokenOwner.selector);
        piece.reveal(SOURCE_KEY);
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.WrongKey.selector);
        piece.reveal(keccak256("a guess"));
        vm.prank(alice);
        vm.expectEmit(address(piece));
        emit ArtifactsPiece.Revealed(SOURCE_KEY);
        piece.reveal(SOURCE_KEY);
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.AlreadyRevealed.selector);
        piece.reveal(SOURCE_KEY);
        assertTrue(piece.revealed());
        assertEq(piece.revealKey(), SOURCE_KEY);

        // the tokenURI call itself, decryption included (measured without copying the 1.8 MB result back)
        {
            bytes memory call_ = abi.encodeWithSelector(ArtifactsPiece.tokenURI.selector, 1);
            address target = address(piece);
            bool fits;
            uint256 g = gasleft();
            assembly {
                fits := staticcall(TOKENURI_GAS_CAP, target, add(call_, 32), mload(call_), 0, 0)
            }
            emit log_named_uint("revealed tokenURI gas", g - gasleft());
            assertTrue(fits, "revealed tokenURI over the gas cap");
        }
        (bool ok, bytes memory ret) =
            address(piece).staticcall(abi.encodeWithSelector(ArtifactsPiece.tokenURI.selector, 1));
        assertTrue(ok);
        bytes memory b = bytes(abi.decode(ret, (string)));
        assertEq(b.length, 29 + payload.length);
        assertEq(Base64Decode.slice(b, 0, 29), bytes("data:application/json;base64,"));
        assertEq(keccak256(Base64Decode.slice(b, 29, b.length)), keccak256(payload), "not decrypted byte for byte");
        // the ABI padding after the string is zero (the last keystream block ran past the end)
        uint256 padded = (b.length + 31) / 32 * 32;
        for (uint256 i = 64 + b.length; i < 64 + padded; ++i) {
            assertEq(uint8(ret[i]), 0, "dirty padding");
        }

        // decode: JSON -> image data URI -> the reference image byte for byte
        bytes memory meta = Base64Decode.decode(payload);
        uint256 at = Base64Decode.indexOf(meta, bytes('"image":"data:image/svg+xml;base64,'), 0) + 35;
        uint256 end = Base64Decode.indexOf(meta, bytes('"}'), at);
        bytes memory svg = Base64Decode.decode(Base64Decode.slice(meta, at, end));
        bytes memory master = bytes(vm.readFile("reference/framed/framed-MASTER.svg"));
        assertEq(keccak256(svg), keccak256(master), "image differs");
        assertEq(Base64Decode.indexOf(meta, bytes(unicode'"name":"ARTIFACTS · THE SOURCE"'), 0), 1);
    }

    /// @dev Any payload length decrypts exactly, including partial last blocks.
    function testFuzz_revealDecryptsAnyLength(bytes memory plain, bytes32 key) public {
        vm.assume(plain.length > 0 && plain.length < 3_000 && key != bytes32(0));
        vm.startPrank(curator);
        source.storePayloadChunk(_sourceCipher(plain, key));
        source.lockPayload(keccak256(abi.encodePacked(key)));
        vm.stopPrank();
        ArtifactsPiece piece = _runAuction();
        vm.prank(alice);
        piece.reveal(key);
        assertEq(bytes(piece.tokenURI(1)), bytes.concat("data:application/json;base64,", plain));
    }

    function test_deliverKeyOnceToTheWinner() public {
        _storePayload();
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.NotSettled.selector);
        source.deliverKey("wrapped");
        ArtifactsPiece piece = _runAuction();
        // the winner must register a viewing key on THE SOURCE's contract first
        vm.prank(curator);
        vm.expectRevert(ArtifactsPiece.NoViewingKey.selector);
        source.deliverKey("wrapped-for-alice");
        vm.prank(alice);
        piece.registerViewingKey(keccak256("alice viewing key"));
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        source.deliverKey("wrapped-for-alice");
        vm.prank(curator);
        vm.expectRevert(ArtifactsPiece.KeyNotPosted.selector);
        source.deliverKey("");
        vm.prank(curator);
        source.deliverKey("wrapped-for-alice");
        assertEq(piece.wrappedKey(), bytes("wrapped-for-alice"));
        assertTrue(source.keyDelivered());
        // one delivery only: after a transfer the previous owner re-wraps, never the curator
        vm.prank(alice);
        piece.transferFrom(alice, bob, 1);
        assertEq(piece.wrappedKey().length, 0);
        vm.prank(bob);
        piece.registerViewingKey(keccak256("bob viewing key"));
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.AlreadyDelivered.selector);
        source.deliverKey("wrapped-for-bob");
        vm.prank(alice);
        piece.rewrapFor("wrapped-for-bob");
        assertEq(piece.wrappedKey(), bytes("wrapped-for-bob"));
    }

    function test_noRevealWhileABuyerIsInEscrow() public {
        _storePayload();
        ArtifactsPiece piece = _runAuction();
        vm.prank(alice);
        piece.list(2 ether);
        vm.prank(bob);
        piece.buy{value: 2 ether}(keccak256("bob vk"), address(0));
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.EscrowActive.selector);
        piece.reveal(SOURCE_KEY);
        vm.prank(bob);
        piece.cancel();
        vm.prank(alice);
        piece.reveal(SOURCE_KEY);
        assertTrue(piece.revealed());
    }

    function test_bidReentrancyAndRefundPull() public {
        vm.prank(curator);
        source.storePayloadChunk("payload");
        vm.prank(curator);
        source.lockPayload(SOURCE_COMMITMENT);
        vm.prank(curator);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 hours));
        // a bidder that reverts on receive cannot block the auction: refunds are pull
        RevertingBidder rb = new RevertingBidder{value: 2 ether}(source);
        rb.bid(1 ether);
        vm.prank(alice);
        source.bid{value: 1.1 ether}(address(0));
        assertEq(source.refunds(address(rb)), 1 ether);
        vm.expectRevert(ArtifactsSource.TransferFailed.selector);
        rb.withdraw();
    }
}

contract RevertingBidder {
    ArtifactsSource internal source;

    constructor(ArtifactsSource s) payable {
        source = s;
    }

    function bid(uint256 v) external {
        source.bid{value: v}(address(0));
    }

    function withdraw() external {
        source.withdrawRefund();
    }

    receive() external payable {
        revert("no");
    }
}
