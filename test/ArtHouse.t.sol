// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtStorage} from "../src/ArtStorage.sol";
import {ArtCollection} from "../src/ArtCollection.sol";
import {TwoStepOwnable} from "../src/base/TwoStepOwnable.sol";
import {ReentrancyGuard} from "../src/base/ReentrancyGuard.sol";
import {Reenterer} from "./mocks/Mocks.sol";
import {Base64Decode} from "./utils/Base64Decode.sol";

contract ArtHouseTest is Fixture {
    ArtCollection internal col;
    bytes internal svg = bytes('<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>');

    function setUp() public override {
        super.setUp();
        vm.prank(curator);
        col = ArtCollection(house.createCollection("Plain", "PLN", artist));
    }

    function _registerAndFinalize(uint256 id) internal {
        vm.startPrank(artist);
        house.registerPiece(address(col), id, keccak256(svg), "Piece", "Desc");
        house.uploadChunk(address(col), id, 0, svg);
        house.finalizePiece(address(col), id);
        vm.stopPrank();
    }

    function _ready(uint256 priceETH, uint256 priceIMD) internal {
        _registerAndFinalize(0);
        _registerAndFinalize(1);
        vm.startPrank(curator);
        house.sealCollection(address(col));
        house.setPrices(address(col), priceETH, priceIMD);
        house.setSaleOpen(address(col), true);
        vm.stopPrank();
    }

    // ---------- deployment / ownership ----------

    function test_deploymentWiring() public view {
        assertEq(house.owner(), curator);
        assertEq(store.owner(), curator);
        assertEq(factory.owner(), curator);
        assertEq(source.owner(), curator);
        assertEq(address(house.artStorage()), address(store));
        assertEq(house.imd(), address(imd));
        assertEq(store.house(), address(house));
        assertEq(col.name(), "Plain");
        assertEq(col.symbol(), "PLN");
    }

    function test_twoStepOwnership_noRenounce() public {
        vm.prank(curator);
        house.transferOwnership(bob);
        assertEq(house.owner(), curator);
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotPendingOwner.selector);
        house.acceptOwnership();
        vm.prank(bob);
        house.acceptOwnership();
        assertEq(house.owner(), bob);
        vm.prank(bob);
        vm.expectRevert(TwoStepOwnable.ZeroAddress.selector);
        house.transferOwnership(address(0));
        // no renounceOwnership selector exists
        (bool ok,) = address(house).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok);
    }

    function test_setHouseOnce() public {
        vm.prank(curator);
        vm.expectRevert(ArtStorage.HouseAlreadySet.selector);
        store.setHouse(alice);
        vm.prank(alice);
        vm.expectRevert(ArtStorage.NotHouse.selector);
        store.write(address(col), 0, 0, svg);
    }

    // ---------- artists / brokers ----------

    function test_artistPayoutOnlyArtist_keptOnReapproval() public {
        vm.prank(alice);
        vm.expectRevert(ArtHouse.NotArtist.selector);
        house.setPayout(bob);
        vm.prank(artist);
        house.setPayout(bob);
        vm.startPrank(curator);
        house.revokeArtist(artist);
        house.approveArtist(artist, "Myles again");
        vm.stopPrank();
        assertEq(house.artistPayout(artist), bob);
        (address to, uint256 amount) = col.royaltyInfo(0, 1 ether);
        assertEq(to, bob);
        assertEq(amount, 0.075 ether);
        assertTrue(col.supportsInterface(0x2a55205a));
    }

    function test_onlyCuratorApproves() public {
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        house.approveArtist(alice, "x");
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        house.setBroker(alice, true);
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        house.setSaleModule(alice, true);
        vm.prank(curator);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.createCollection("X", "X", alice);
    }

    // ---------- curation ----------

    function test_curationFlow_andFailures() public {
        vm.prank(alice);
        vm.expectRevert(ArtHouse.NotCurator.selector);
        house.registerPiece(address(col), 0, keccak256(svg), "P", "D");
        vm.startPrank(artist);
        vm.expectRevert(ArtHouse.BadPieceId.selector);
        house.registerPiece(address(col), 1, keccak256(svg), "P", "D");
        house.registerPiece(address(col), 0, keccak256(svg), "P", "D");
        vm.expectRevert(ArtHouse.BadIndex.selector);
        house.uploadChunk(address(col), 0, 1, svg);
        house.uploadChunk(address(col), 0, 0, hex"00");
        vm.expectRevert(ArtHouse.HashMismatch.selector);
        house.finalizePiece(address(col), 0);
        vm.stopPrank();
        vm.prank(curator);
        house.clearPiece(address(col), 0);
        assertEq(store.chunkCount(address(col), 0), 0);
        vm.startPrank(artist);
        house.uploadChunk(address(col), 0, 0, svg);
        house.finalizePiece(address(col), 0);
        vm.expectRevert(ArtHouse.Finalized.selector);
        house.uploadChunk(address(col), 0, 1, svg);
        vm.stopPrank();
        vm.prank(curator);
        vm.expectRevert(ArtHouse.Finalized.selector);
        house.clearPiece(address(col), 0);
        vm.prank(curator);
        vm.expectRevert(ArtHouse.NotSealed.selector);
        house.setSaleOpen(address(col), true);
        vm.prank(curator);
        house.sealCollection(address(col));
        vm.prank(artist);
        vm.expectRevert(ArtHouse.Sealed.selector);
        house.registerPiece(address(col), 1, keccak256(svg), "P", "D");
    }

    /// @dev A mistyped content hash is correctable while the piece is unfinalized, so the collection is not
    /// stranded; once finalized or sealed it is fixed.
    function test_wrongHashIsCorrectable() public {
        vm.startPrank(artist);
        house.registerPiece(address(col), 0, keccak256("typo"), "P", "D");
        house.uploadChunk(address(col), 0, 0, svg);
        vm.expectRevert(ArtHouse.HashMismatch.selector);
        house.finalizePiece(address(col), 0);
        vm.expectRevert(ArtHouse.BadPieceId.selector);
        house.registerPiece(address(col), 0, keccak256(svg), "P", "D");
        vm.expectRevert(ArtHouse.BadPieceId.selector);
        house.updatePiece(address(col), 1, keccak256(svg), "P", "D");
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(ArtHouse.NotCurator.selector);
        house.updatePiece(address(col), 0, keccak256(svg), "P", "D");
        vm.prank(curator);
        house.updatePiece(address(col), 0, keccak256(svg), "Fixed", "Desc");
        (bytes32 hash, string memory title,,,,) = house.pieces(address(col), 0);
        assertEq(hash, keccak256(svg));
        assertEq(title, "Fixed");
        assertEq(store.chunkCount(address(col), 0), 1); // chunks are kept
        vm.prank(artist);
        house.finalizePiece(address(col), 0);
        vm.prank(artist);
        vm.expectRevert(ArtHouse.Finalized.selector);
        house.updatePiece(address(col), 0, keccak256("x"), "P", "D");
        vm.prank(curator);
        house.sealCollection(address(col));
        vm.prank(curator);
        vm.expectRevert(ArtHouse.Sealed.selector);
        house.updatePiece(address(col), 0, keccak256("x"), "P", "D");
        vm.prank(curator);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.updatePiece(address(factory), 0, keccak256("x"), "P", "D");
    }

    /// @dev Revoking an artist ends their curation rights over existing collections; re-approval restores them.
    function test_revokedArtistLosesCuration() public {
        vm.prank(artist);
        house.registerPiece(address(col), 0, keccak256(svg), "P", "D");
        vm.prank(curator);
        house.revokeArtist(artist);
        vm.startPrank(artist);
        vm.expectRevert(ArtHouse.NotCurator.selector);
        house.registerPiece(address(col), 1, keccak256(svg), "P", "D");
        vm.expectRevert(ArtHouse.NotCurator.selector);
        house.uploadChunk(address(col), 0, 0, svg);
        vm.expectRevert(ArtHouse.NotCurator.selector);
        house.updatePiece(address(col), 0, keccak256(svg), "P", "D");
        vm.expectRevert(ArtHouse.NotCurator.selector);
        house.finalizePiece(address(col), 0);
        vm.stopPrank();
        // the curator still can
        vm.prank(curator);
        house.uploadChunk(address(col), 0, 0, svg);
        vm.prank(curator);
        house.approveArtist(artist, "Myles");
        vm.prank(artist);
        house.finalizePiece(address(col), 0);
    }

    function test_pieceOver100KBRejected() public {
        vm.startPrank(artist);
        house.registerPiece(address(col), 0, bytes32(uint256(1)), "P", "D");
        bytes memory big = new bytes(24_000);
        for (uint256 i; i < 4; ++i) {
            house.uploadChunk(address(col), 0, i, big);
        }
        vm.expectRevert(ArtHouse.TooLarge.selector);
        house.uploadChunk(address(col), 0, 4, new bytes(4_001));
        house.uploadChunk(address(col), 0, 4, new bytes(4_000));
        vm.stopPrank();
    }

    function test_sealNeedsEveryPieceFinalized() public {
        _registerAndFinalize(0);
        vm.prank(artist);
        house.registerPiece(address(col), 1, keccak256(svg), "P", "D");
        vm.prank(curator);
        vm.expectRevert(ArtHouse.NotFinalized.selector);
        house.sealCollection(address(col));
    }

    // ---------- buying & split invariant ----------

    function testFuzz_ethSplitInvariant(uint96 price, bool useBroker, bool brokerIsBuyer) public {
        vm.assume(price > 0);
        _ready(price, 0);
        address b = useBroker ? (brokerIsBuyer ? alice : broker) : address(0);
        vm.deal(alice, price);
        vm.prank(alice);
        house.mint{value: price}(address(col), 0, b);
        assertEq(col.ownerOf(0), alice);
        uint256 artistBal = house.balances(artist, address(0));
        uint256 brokerBal = house.balances(broker, address(0));
        uint256 houseBal = house.balances(address(house), address(0));
        assertEq(artistBal + brokerBal + houseBal, price, "conservation");
        assertEq(artistBal, uint256(price) * 7000 / 10_000);
        if (useBroker && !brokerIsBuyer) {
            assertEq(brokerBal, uint256(price) * 1500 / 10_000);
        } else {
            assertEq(brokerBal, 0);
            assertGe(houseBal, uint256(price) * 3000 / 10_000);
        }
        assertEq(address(house).balance, price);
        // withdrawals drain exactly the balances
        if (artistBal > 0) {
            vm.prank(artist);
            house.withdraw(address(0));
            assertEq(artist.balance, artistBal);
        }
        vm.prank(curator);
        house.withdrawHouse(address(0));
        assertEq(curator.balance, houseBal);
        if (brokerBal > 0) {
            vm.prank(broker);
            house.withdraw(address(0));
            assertEq(broker.balance, brokerBal);
        }
        assertEq(address(house).balance, 0);
    }

    function testFuzz_imdSplitInvariant(uint96 price, bool useBroker) public {
        vm.assume(price > 0);
        _ready(0, price);
        imd.mint(alice, price);
        vm.prank(alice);
        imd.approve(address(house), price);
        vm.prank(alice);
        house.mintWithIMD(address(col), 1, useBroker ? broker : address(0), price);
        assertEq(col.ownerOf(1), alice);
        uint256 artistBal = house.balances(artist, address(imd));
        uint256 brokerBal = house.balances(broker, address(imd));
        uint256 houseBal = house.balances(address(house), address(imd));
        assertEq(artistBal + brokerBal + houseBal, price);
        assertEq(imd.balanceOf(address(house)), price);
        assertEq(brokerBal, useBroker ? uint256(price) * 1500 / 10_000 : 0);
        // ETH balances untouched
        assertEq(house.balances(artist, address(0)), 0);
        if (artistBal > 0) {
            vm.prank(artist);
            house.withdraw(address(imd));
            assertEq(imd.balanceOf(artist), artistBal);
        }
    }

    function test_mintFailures() public {
        vm.prank(alice);
        vm.expectRevert(ArtHouse.SaleClosed.selector);
        house.mint{value: 1 ether}(address(col), 0, address(0));
        _ready(1 ether, 100e18);
        vm.startPrank(alice);
        vm.expectRevert(ArtHouse.WrongPrice.selector);
        house.mint{value: 0.5 ether}(address(col), 0, address(0));
        vm.expectRevert(ArtHouse.BadPieceId.selector);
        house.mint{value: 1 ether}(address(col), 5, address(0));
        house.mint{value: 1 ether}(address(col), 0, address(0));
        vm.expectRevert(ArtHouse.AlreadyMinted.selector);
        house.mint{value: 1 ether}(address(col), 0, address(0));
        vm.expectRevert(ArtHouse.WrongPrice.selector);
        house.mintWithIMD(address(col), 1, address(0), 99e18);
        vm.expectRevert(); // no allowance
        house.mintWithIMD(address(col), 1, address(0), 100e18);
        vm.stopPrank();
        vm.prank(curator);
        house.setSaleOpen(address(col), false);
        vm.prank(alice);
        vm.expectRevert(ArtHouse.SaleClosed.selector);
        house.mint{value: 1 ether}(address(col), 1, address(0));
    }

    function test_recordSaleOnlyModules() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(ArtHouse.NotSaleModule.selector);
        house.recordSale{value: 1 ether}(address(factory), alice, address(0));
        vm.prank(address(factory));
        vm.expectRevert(ArtHouse.NotModuleCollection.selector);
        house.recordSale{value: 0}(address(col), alice, address(0));
    }

    function test_customSplit() public {
        vm.prank(curator);
        vm.expectRevert(ArtHouse.BadSplit.selector);
        house.setSplit(address(col), 1000, 1000, 1000);
        vm.prank(curator);
        house.setSplit(address(col), 1000, 2000, 7000);
        _ready(1 ether, 0);
        vm.prank(alice);
        house.mint{value: 1 ether}(address(col), 0, broker);
        assertEq(house.balances(broker, address(0)), 0.1 ether);
        assertEq(house.balances(address(house), address(0)), 0.2 ether);
        assertEq(house.balances(artist, address(0)), 0.7 ether);
    }

    function test_withdrawNothingReverts_andHouseGoesToCurrentOwner() public {
        vm.prank(alice);
        vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
        house.withdraw(address(0));
        _ready(1 ether, 0);
        vm.prank(alice);
        house.mint{value: 1 ether}(address(col), 0, address(0));
        vm.prank(curator);
        house.transferOwnership(bob);
        vm.prank(bob);
        house.acceptOwnership();
        vm.prank(curator);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        house.withdrawHouse(address(0));
        vm.prank(bob);
        house.withdrawHouse(address(0));
        assertEq(bob.balance, 1000 ether + 0.3 ether);
    }

    function test_reentrancyOnWithdrawBlocked() public {
        _ready(1 ether, 0);
        Reenterer r = new Reenterer();
        vm.deal(address(r), 2 ether);
        vm.prank(curator);
        house.setBroker(address(r), true);
        vm.prank(alice);
        house.mint{value: 1 ether}(address(col), 0, address(r));
        r.set(address(house), abi.encodeWithSelector(ArtHouse.withdraw.selector, address(0)));
        r.call(address(house), 0, abi.encodeWithSelector(ArtHouse.withdraw.selector, address(0)));
        assertTrue(r.reentryFailed());
        assertEq(address(r).balance, 2 ether + 0.15 ether);
        // re-entering mint from a mint-triggered callback is impossible: no callback exists, and the guard holds
        r.set(address(house), abi.encodeWithSelector(ArtHouse.mint.selector, address(col), 1, address(0)));
        vm.prank(curator);
        house.withdrawHouse(address(0));
    }

    function test_tokenURIOnChain() public {
        _ready(1 ether, 0);
        vm.prank(alice);
        house.mint{value: 1 ether}(address(col), 0, address(0));
        string memory uri = col.tokenURI(0);
        bytes memory b = bytes(uri);
        bytes memory prefix = "data:application/json;base64,";
        assertEq(Base64Decode.slice(b, 0, prefix.length), prefix);
        bytes memory json = Base64Decode.decode(Base64Decode.slice(b, prefix.length, b.length));
        uint256 at = Base64Decode.indexOf(json, bytes("data:image/svg+xml;base64,"), 0) + 26;
        uint256 end = Base64Decode.indexOf(json, bytes('"}'), at);
        assertEq(Base64Decode.decode(Base64Decode.slice(json, at, end)), svg);
        vm.expectRevert();
        col.tokenURI(1);
    }

    function test_submissions() public {
        vm.prank(alice);
        uint256 id = house.submit(keccak256("work"), "ipfs://preview");
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        house.decideSubmission(id, true);
        vm.prank(curator);
        house.decideSubmission(id, true);
        (,,, ArtHouse.SubmissionStatus status) = house.submissions(id);
        assertEq(uint8(status), uint8(ArtHouse.SubmissionStatus.Accepted));
        vm.prank(curator);
        vm.expectRevert(ArtHouse.NotPending.selector);
        house.decideSubmission(id, false);
    }

    function test_collectionMintOnlyHouse() public {
        vm.prank(alice);
        vm.expectRevert(ArtCollection.NotHouse.selector);
        col.mint(alice, 0);
        ArtCollection impl = ArtCollection(house.collectionImplementation());
        vm.expectRevert(ArtCollection.AlreadyInitialized.selector);
        impl.initialize(alice, "x", "x");
    }
}
