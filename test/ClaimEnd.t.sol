// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {TwoStepOwnable} from "../src/base/TwoStepOwnable.sol";

/// @dev claimMany: several editions in one transaction, each exactly as claim. endSale: the edition sale over for
/// good, with draws already paid for still completing and every buyer still able to claim.
contract ClaimEndTest is Fixture {
    uint256 internal constant P = 0.01 ether;

    function setUp() public override {
        super.setUp();
        _publishAll();
        _openSale(P);
    }

    function _ready(address buyer, uint256 word) internal returns (uint256 edition) {
        edition = _buyAndAssign(buyer, address(0), word);
        vm.prank(curator);
        factory.postWrappedKey(edition, abi.encodePacked("wrapped", edition));
    }

    function _keyFor(address buyer) internal {
        vm.prank(buyer);
        factory.registerViewingKey(keccak256(abi.encodePacked("vk", buyer)));
    }

    // ---------- claimMany ----------

    function test_claimMany_claimsEveryOneInOneCall() public {
        _keyFor(alice);
        uint256[] memory eds = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            eds[i] = _ready(alice, 7 + i);
        }
        vm.prank(alice);
        address[] memory pieces = factory.claimMany(eds);
        assertEq(pieces.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(factory.pieceContract(eds[i]), pieces[i]);
            assertEq(ArtifactsPiece(pieces[i]).ownerOf(1), alice);
            assertEq(ArtifactsPiece(pieces[i]).pieceId(), eds[i]);
        }
    }

    function test_claimMany_isAllOrNothing() public {
        _keyFor(alice);
        uint256 a = _ready(alice, 1);
        uint256 b = _buyAndAssign(alice, address(0), 2); // its key not posted yet
        uint256[] memory eds = new uint256[](2);
        eds[0] = a;
        eds[1] = b;
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.KeyNotPosted.selector);
        factory.claimMany(eds);
        assertEq(factory.pieceContract(a), address(0), "nothing claimed when one fails");

        // someone else's edition in the list: refused, nothing claimed
        _keyFor(bob);
        uint256 c = _ready(bob, 3);
        eds[1] = c;
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.NotBuyer.selector);
        factory.claimMany(eds);

        // the same edition twice: the second is already claimed
        eds[1] = a;
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.AlreadyClaimed.selector);
        factory.claimMany(eds);
    }

    function test_claimMany_emptyRefused_andTheCuratorCanClaimForBuyers() public {
        vm.prank(alice);
        vm.expectRevert(ArtifactsFactory.NothingToClaim.selector);
        factory.claimMany(new uint256[](0));

        _keyFor(alice);
        _keyFor(bob);
        uint256[] memory eds = new uint256[](2);
        eds[0] = _ready(alice, 4);
        eds[1] = _ready(bob, 5);
        vm.prank(curator);
        address[] memory pieces = factory.claimMany(eds);
        assertEq(ArtifactsPiece(pieces[0]).ownerOf(1), alice, "each token goes to its buyer");
        assertEq(ArtifactsPiece(pieces[1]).ownerOf(1), bob);
    }

    // ---------- endSale ----------

    function test_endSale_isFinal() public {
        _buyAndAssign(alice, address(0), 1);
        vm.prank(alice);
        uint256 pendingId = factory.buy{value: P}(address(0)); // paid, not drawn yet
        uint256 soldBefore = factory.sold();

        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        factory.endSale();

        vm.expectEmit(address(factory));
        emit ArtifactsFactory.SaleEnded(soldBefore);
        vm.prank(curator);
        factory.endSale();
        assertTrue(factory.saleEnded());
        assertFalse(factory.saleOpen());
        assertEq(factory.remaining(), 0, "nothing left to sell");
        assertEq(factory.allowanceOf(bob), 0, "nobody may buy more");

        // closed for good: no buying, no reopening, no second end
        vm.prank(bob);
        vm.expectRevert(ArtifactsFactory.SaleClosed.selector);
        factory.buy{value: P}(address(0));
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.SaleOver.selector);
        factory.setSaleOpen(true);
        vm.expectRevert(ArtifactsFactory.SaleOver.selector);
        factory.endSale();
        vm.stopPrank();

        // what was paid for still completes, and can be claimed
        vrf.fulfill(pendingId, 9);
        uint256 edition = factory.requestEdition(pendingId);
        assertGt(edition, 0, "the paid draw completes after the end");
        ArtifactsPiece piece = _claim(alice, edition);
        assertEq(piece.ownerOf(1), alice);
        assertEq(factory.sold(), soldBefore, "the supply is fixed");
    }

    function test_endSale_needsTheSaleToHaveOpened_andWorksWhileClosed() public {
        // a fresh factory state: this one has opened, so close it and end it while closed
        vm.startPrank(curator);
        factory.setSaleOpen(false);
        factory.endSale();
        vm.stopPrank();
        assertTrue(factory.saleEnded());
    }
}

/// @dev endSale before the sale has ever opened is refused: ending a drop that never sold is not a choice to make by
/// accident.
contract EndBeforeOpenTest is Fixture {
    function test_endSale_beforeOpening_refused() public {
        _publishAll();
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.NeverOpened.selector);
        factory.endSale();
    }
}
