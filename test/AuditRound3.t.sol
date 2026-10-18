// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtHouse} from "../src/ArtHouse.sol";

/// @dev An artist payout that, paid during a resale's release, tries to act on the piece as its seller: re-list it
/// for 1 wei, or move it away. It accepts the ETH either way.
contract ReentryPayout {
    ArtifactsPiece public piece;
    uint256 public armed; // 1 list, 2 transfer
    bool public listFailed;
    bool public moveFailed;

    function setPiece(ArtifactsPiece p) external {
        piece = p;
    }

    function arm(uint256 how) external {
        armed = how;
    }

    function listIt(uint256 price) external {
        piece.list(price);
    }

    function postKey(bytes calldata wrapped, address r, uint256 z) external payable {
        piece.postEscrowKey{value: msg.value}(wrapped, r, z);
    }

    receive() external payable {
        uint256 how = armed;
        if (how == 0) return;
        armed = 0;
        if (how == 1) {
            try piece.list(1) {}
            catch {
                listFailed = true;
            }
        } else {
            try piece.transferFrom(address(this), address(0xBEEF), 1) {}
            catch {
                moveFailed = true;
            }
        }
    }
}

/// @dev A payout that answers with 60 KB of return data, to make the payer copy it.
contract ReturnBombPayout {
    receive() external payable {
        assembly {
            return(0, 60000)
        }
    }
}

/// @dev Third review round: the artist's direct payment can't reach into a release, can't bomb the payer with return
/// data, and a share that waits in the ledger says so.
contract AuditRound3Test is Fixture {
    ArtifactsPiece internal piece;
    ReentryPayout internal evil;

    function setUp() public override {
        super.setUp();
        _publishAll();
        _openSale(1 ether);
        uint256 edition = _buyAndAssign(alice, address(0), 10);
        piece = _claim(alice, edition);
        evil = new ReentryPayout();
        evil.setPiece(piece);
        vm.prank(artist);
        house.setPayout(address(evil));
        // the artist's own contract holds the piece and sells it through the escrow
        vm.prank(alice);
        piece.transferFrom(alice, address(evil), 1);
        evil.listIt(10 ether);
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        piece.buy{value: 10 ether}(_vk("bobvk"), address(0));
        (bytes memory wrapped, address r, uint256 z) = _sellerKey(piece, "key");
        vm.deal(address(evil), 1 ether);
        evil.postKey{value: 1 ether}(wrapped, r, z);
    }

    function _releaseArmed(uint256 how) internal {
        evil.arm(how);
        uint256 before = address(evil).balance;
        vm.prank(bob);
        piece.release();
        assertEq(address(evil).balance - before, 0.75 ether, "the royalty was paid to the artist's payout, directly");
        assertEq(piece.ownerOf(1), bob);
    }

    function test_theArtistsPayoutCantRelistDuringARelease() public {
        _releaseArmed(1);
        assertTrue(evil.listFailed(), "the piece was the buyer's before the payout was called");
        // nothing was left listed: the buyer lists, and moves, the piece freely
        vm.prank(bob);
        piece.list(3 ether);
        vm.prank(bob);
        piece.delist();
        vm.prank(bob);
        piece.transferFrom(bob, carol, 1);
        assertEq(piece.ownerOf(1), carol);
    }

    function test_theArtistsPayoutCantMoveThePieceDuringARelease() public {
        _releaseArmed(2);
        assertTrue(evil.moveFailed());
        assertEq(piece.wrappedKey(), _wrappedOf("key"), "the buyer has its key");
        assertEq(
            piece.pendingWithdrawals(address(evil)),
            10 ether - 0.75 ether + 1 ether,
            "price less royalty, and the deposit"
        );
    }

    function test_aReturnDataBombCostsThePayerNothing() public {
        ReturnBombPayout bomb = new ReturnBombPayout();
        vm.prank(artist);
        house.setPayout(alice); // a plain wallet, for the baseline
        vm.deal(carol, 10 ether);
        uint256 g0 = gasleft();
        vm.prank(carol);
        factory.buy{value: 1 ether}(address(0));
        uint256 plain = g0 - gasleft();
        vm.prank(artist);
        house.setPayout(address(bomb));
        vm.deal(carol, 10 ether);
        g0 = gasleft();
        vm.prank(carol);
        factory.buy{value: 1 ether}(address(0));
        uint256 bombed = g0 - gasleft();
        assertEq(address(bomb).balance, 0.75 ether, "paid");
        // the bomb's own memory costs it about 12k; copying its 60 KB back would cost the buyer as much again
        assertLt(bombed, plain + 22_000, "nothing returned is copied");
    }

    function test_aShareThatWaitsInTheLedgerIsAnnounced() public {
        vm.prank(artist);
        house.setPayout(address(house)); // no receive: it can't take ETH
        vm.deal(carol, 10 ether);
        vm.expectEmit(address(house));
        emit ArtHouse.ArtistCredited(artist, address(0), 0.75 ether);
        vm.prank(carol);
        factory.buy{value: 1 ether}(address(0));
        assertEq(house.balances(artist, address(0)), 0.75 ether);
    }
}
