// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {TwoStepOwnable} from "../src/base/TwoStepOwnable.sol";
import {Base64Decode} from "./utils/Base64Decode.sol";
import {Seal} from "../src/libs/Seal.sol";

contract ArtifactsSourceTest is Fixture {
    uint256 internal constant CHUNK = 24_000;
    /// @dev What the revealed tokenURI must fit in, so public RPCs can serve it to marketplaces.
    uint256 internal constant TOKENURI_GAS_CAP = 3_000_000;

    /// @dev Stores the renderer page (as the ceremony writes it) and locks it with the test seed, sealed.
    function _storeSource() internal returns (bytes memory page) {
        page = bytes(vm.readFile("reference/the-source.renderer.html"));
        vm.startPrank(curator);
        source.storeRendererChunk(page);
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
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

    function test_auctionNeedsTheSourceLocked() public {
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.NotLocked.selector);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 days));
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        source.storeRendererChunk("x");
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsSource.EmptyRenderer.selector);
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        source.storeRendererChunk("abc");
        vm.expectRevert(ArtifactsSource.NoCommitment.selector);
        source.lock(SEALED_SEED, bytes32(0));
        source.resetRenderer();
        source.storeRendererChunk("abcd");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        vm.expectRevert(ArtifactsSource.IsLocked.selector);
        source.storeRendererChunk("more");
        vm.expectRevert(ArtifactsSource.IsLocked.selector);
        source.resetRenderer();
        vm.stopPrank();
        assertEq(source.rendererHash(), keccak256("abcd"));
        assertEq(source.rendererSize(), 4);
        assertEq(source.keyCommitment(), SOURCE_COMMITMENT);
    }

    /// @dev The 5% raise rounds up, so even dust-sized bids must strictly exceed the high bid.
    function test_tinyBidsMustStrictlyExceed() public {
        vm.startPrank(curator);
        source.storeRendererChunk("x");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
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
        source.storeRendererChunk("payload");
        vm.prank(curator);
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
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
        // proceeds went through the ledger (no broker on the winning bid => the broker share buys back and burns)
        assertEq(house.balances(artist, address(0)), 1.5 ether);
        assertEq(house.balances(address(house), address(0)), 0.1 ether);
        assertEq(house.balances(house.BUYBACK(), address(0)), 0.4 ether);
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
        source.storeRendererChunk("payload");
        vm.prank(curator);
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        vm.prank(curator);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 hours));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.expectRevert(ArtifactsSource.NoBids.selector);
        source.settle();
        vm.prank(curator);
        source.setAuction(0.5 ether, uint64(vm.getBlockTimestamp() + 1 hours));
        assertEq(source.reserve(), 0.5 ether);
    }

    function test_storedSeedIsSealed() public {
        bytes memory page = _storeSource();
        assertEq(source.rendererHash(), keccak256(page));
        assertEq(source.sealedSeed(), SEALED_SEED);
        assertTrue(source.sealedSeed() != SOURCE_SEED, "the seed is stored in the clear");
        assertEq(source.keyCommitment(), SOURCE_COMMITMENT);
        ArtifactsPiece piece = _runAuction();
        assertEq(piece.commitment(), SOURCE_COMMITMENT, "the piece carries the key commitment");
        assertFalse(piece.revealed());
        assertEq(piece.revealedSeed(), bytes32(0));
        assertEq(piece.revealKey(), bytes32(0));
    }

    function test_revealServesTheRendererWithItsSeed() public {
        bytes memory page = _storeSource();
        ArtifactsPiece piece = _runAuction();
        // sealed until revealed: the R9 frame, marked SEALED
        bytes memory sealedUri = bytes(piece.tokenURI(1));
        bytes memory json = Base64Decode.decode(Base64Decode.slice(sealedUri, 29, sealedUri.length));
        bytes memory frameOnly;
        {
            uint256 sAt = Base64Decode.indexOf(json, bytes("data:image/svg+xml;base64,"), 0) + 26;
            uint256 sEnd = Base64Decode.indexOf(json, bytes('"}'), sAt);
            bytes memory sealSvg = Base64Decode.decode(Base64Decode.slice(json, sAt, sEnd));
            bytes memory framed = bytes(vm.readFile("reference/framed/framed-MASTER.svg"));
            uint256 frameAt = Base64Decode.indexOf(framed, bytes('<g fill="#1a1a1a"'), 0);
            uint256 dotsAt = Base64Decode.indexOf(framed, bytes("<circle"), 0);
            frameOnly =
                bytes.concat(Base64Decode.slice(framed, 0, dotsAt), Base64Decode.slice(framed, frameAt, framed.length));
            assertEq(sealSvg, Base64Decode.withMark(frameOnly, Seal.SEALED_MARK), "THE SOURCE seal differs from R9 frame");
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
        assertEq(piece.revealedSeed(), SOURCE_SEED, "the key opens the seed");

        // the tokenURI call itself, measured without copying the result back
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
        bytes memory uri = bytes(piece.tokenURI(1));
        assertEq(Base64Decode.slice(uri, 0, 29), bytes("data:application/json;base64,"));
        bytes memory meta = Base64Decode.decode(Base64Decode.slice(uri, 29, uri.length));
        string memory seedHex = vm.toString(SOURCE_SEED);
        // the page is the stored renderer, then the seed, then the closing the contract adds
        uint256 at = Base64Decode.indexOf(meta, bytes('"animation_url":"data:text/html;base64,'), 0) + 39;
        uint256 end = Base64Decode.indexOf(meta, bytes('"}'), at);
        bytes memory shown = Base64Decode.decode(Base64Decode.slice(meta, at, end));
        assertEq(keccak256(shown), keccak256(bytes.concat(page, bytes(seedHex), bytes(piece.RENDER_SUFFIX()))), "page differs");
        // the still image is the same frame, now marked REVEALED (the art is the animation); the seed is a public
        // attribute; the name holds
        assertTrue(Base64Decode.indexOf(meta, bytes.concat('"Seed","value":"', bytes(seedHex), '"'), 0) > 0);
        uint256 imgAt = Base64Decode.indexOf(meta, bytes("data:image/svg+xml;base64,"), 0) + 26;
        uint256 imgEnd = Base64Decode.indexOf(meta, bytes('","animation_url"'), imgAt);
        bytes memory still = Base64Decode.decode(Base64Decode.slice(meta, imgAt, imgEnd));
        assertEq(still, Base64Decode.withMark(frameOnly, Seal.REVEALED_MARK));
        assertTrue(Base64Decode.indexOf(still, bytes(">REVEALED<"), 0) > 0);
        assertEq(Base64Decode.indexOf(meta, bytes(unicode'"name":"ARTIFACTS · THE SOURCE"'), 0), 1);
    }

    /// @dev Any seed and key: the published key opens exactly the seed that was sealed with it.
    function testFuzz_revealOpensTheSealedSeed(bytes32 seed, bytes32 key) public {
        vm.assume(key != bytes32(0));
        vm.startPrank(curator);
        source.storeRendererChunk("page");
        source.lock(seed ^ keccak256(abi.encodePacked(key, uint256(0))), keccak256(abi.encodePacked(key)));
        vm.stopPrank();
        ArtifactsPiece piece = _runAuction();
        vm.prank(alice);
        piece.reveal(key);
        assertEq(piece.revealedSeed(), seed);
    }

    function test_deliverKeyOnceToTheWinner() public {
        _storeSource();
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

    /// @dev The auction only opens once the house will accept its sale, so a winning bid can always settle.
    function test_auctionNeedsTheHouseToAcceptTheSale() public {
        _storeSource();
        vm.prank(curator);
        house.setSaleModule(address(source), false);
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.NotRegistered.selector);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 days));
        vm.prank(curator);
        house.setSaleModule(address(source), true);
        vm.prank(curator);
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 days));
        assertTrue(source.auctionOpen());
    }

    /// @dev A listing made while sealed comes down when the owner reveals; nobody can buy it at the sealed price.
    function test_revealTakesDownAListingWithNoBuyer() public {
        _storeSource();
        ArtifactsPiece piece = _runAuction();
        vm.prank(alice);
        piece.list(2 ether);
        vm.expectEmit(address(piece));
        emit ArtifactsPiece.Delisted();
        vm.prank(alice);
        piece.reveal(SOURCE_KEY);
        (, address seller,,,,,,,,) = piece.escrow();
        assertEq(seller, address(0));
        vm.prank(bob);
        vm.expectRevert(ArtifactsPiece.NotListed.selector);
        piece.buy{value: 2 ether}(_vk("bob vk"), address(0));
        // the owner can list it again, revealed
        vm.prank(alice);
        piece.list(3 ether);
    }

    function test_noRevealWhileABuyerIsInEscrow() public {
        _storeSource();
        ArtifactsPiece piece = _runAuction();
        vm.prank(alice);
        piece.list(2 ether);
        vm.prank(bob);
        piece.buy{value: 2 ether}(_vk("bob vk"), address(0));
        vm.prank(alice);
        vm.expectRevert(ArtifactsPiece.EscrowActive.selector);
        piece.reveal(SOURCE_KEY);
        vm.warp(vm.getBlockTimestamp() + 24 hours); // the seller's window
        vm.prank(bob);
        piece.cancel();
        vm.prank(alice);
        piece.reveal(SOURCE_KEY);
        assertTrue(piece.revealed());
    }

    function test_bidReentrancyAndRefundPull() public {
        vm.prank(curator);
        source.storeRendererChunk("payload");
        vm.prank(curator);
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
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
