// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {MockSeats} from "./mocks/MockSeats.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {TwoStepOwnable} from "../src/base/TwoStepOwnable.sol";

/// @dev Mint phases inside the holders window: 1 per wallet (and per seat) for the first hour, 2 in all for the next
/// hour, then 5; the same counts for a wallet and for a seat, wherever the seat goes.
contract PhasesTest is Fixture {
    MockSeats internal seats;
    uint256 internal constant MIN_IMD = 10e18;
    uint256 internal constant P = 0.01 ether;

    function setUp() public override {
        super.setUp();
        seats = new MockSeats();
        _publishAll();
        vm.startPrank(curator);
        factory.setGate(address(seats), address(imd), MIN_IMD, 24 hours);
        factory.setMintPhases(1 hours, 1, 1 hours, 2);
        vm.stopPrank();
    }

    function test_capsRise_1_then_2_then_5_forAnImdHolder() public {
        (uint256 cap, uint256 ends) = factory.currentPhase();
        assertEq(cap, 1, "before the sale opens: the first phase's limit");
        assertEq(ends, 0);
        _openSale(P);
        uint256 opened = factory.saleOpenedAt();
        imd.mint(alice, MIN_IMD);

        (cap, ends) = factory.currentPhase();
        assertEq(cap, 1);
        assertEq(ends, opened + 1 hours);
        assertEq(factory.allowanceOf(alice), 1);
        vm.startPrank(alice);
        factory.buy{value: P}(address(0));
        vm.expectRevert(ArtifactsFactory.WalletLimit.selector);
        factory.buy{value: P}(address(0));
        vm.stopPrank();
        assertEq(factory.allowanceOf(alice), 0);

        vm.warp(opened + 1 hours); // phase 2: two in all
        (cap, ends) = factory.currentPhase();
        assertEq(cap, 2);
        assertEq(ends, opened + 2 hours);
        assertEq(factory.allowanceOf(alice), 1);
        vm.startPrank(alice);
        vm.expectRevert(ArtifactsFactory.WalletLimit.selector);
        factory.buyMany{value: 2 * P}(2, address(0)); // would make three
        factory.buy{value: P}(address(0));
        vm.stopPrank();

        vm.warp(opened + 2 hours); // the rest of the window: five in all
        (cap, ends) = factory.currentPhase();
        assertEq(cap, 5);
        assertEq(ends, 0);
        assertEq(factory.allowanceOf(alice), 3);
        vm.startPrank(alice);
        factory.buyMany{value: 3 * P}(3, address(0));
        vm.expectRevert(ArtifactsFactory.WalletLimit.selector);
        factory.buy{value: P}(address(0));
        vm.stopPrank();
        assertEq(factory.mintedBy(alice), 5);
    }

    function test_aSeatFollowsThePhases_whereverItGoes() public {
        seats.mint(bob, 42);
        _openSale(P);
        uint256 opened = factory.saleOpenedAt();
        vm.prank(bob);
        factory.buyWithSeat{value: P}(42, 1, address(0));
        vm.prank(bob);
        vm.expectRevert(ArtifactsFactory.SeatLimit.selector);
        factory.buyWithSeat{value: P}(42, 1, address(0));
        // the seat moves to a fresh wallet: it has used its one for this phase
        vm.prank(bob);
        seats.transferFrom(bob, carol, 42);
        vm.prank(carol);
        vm.expectRevert(ArtifactsFactory.SeatLimit.selector);
        factory.buyWithSeat{value: P}(42, 1, address(0));
        vm.warp(opened + 1 hours);
        vm.prank(carol);
        factory.buyWithSeat{value: P}(42, 1, address(0)); // two in all for the seat
        assertEq(factory.mintedBySeat(42), 2);
        vm.prank(carol);
        vm.expectRevert(ArtifactsFactory.SeatLimit.selector);
        factory.buyWithSeat{value: P}(42, 1, address(0));
        vm.warp(opened + 2 hours);
        vm.prank(carol);
        factory.buyWithSeat{value: 3 * P}(42, 3, address(0));
        assertEq(factory.mintedBySeat(42), 5);
    }

    function test_afterTheWindow_anyoneUpToFive() public {
        _openSale(P);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(dave());
        factory.buyMany{value: 5 * P}(5, address(0));
        assertEq(factory.mintedBy(dave()), 5);
    }

    function test_setOnlyBeforeTheSaleOpens_andChecked() public {
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.BadPhases.selector);
        factory.setMintPhases(1 hours, 0, 1 hours, 2); // a phase with no limit
        vm.expectRevert(ArtifactsFactory.BadPhases.selector);
        factory.setMintPhases(1 hours, 6, 0, 0); // over the per-wallet maximum
        vm.expectRevert(ArtifactsFactory.BadPhases.selector);
        factory.setMintPhases(1 hours, 3, 1 hours, 2); // limits must rise
        factory.setMintPhases(0, 0, 0, 0); // cleared: five throughout
        (uint256 cap,) = factory.currentPhase();
        assertEq(cap, 5);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(TwoStepOwnable.NotOwner.selector);
        factory.setMintPhases(1 hours, 1, 1 hours, 2);
        _openSale(P);
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.SaleIsOpen.selector);
        factory.setMintPhases(1 hours, 1, 1 hours, 2);
    }

    function dave() internal returns (address d) {
        d = makeAddr("dave");
        vm.deal(d, 10 ether);
    }
}
