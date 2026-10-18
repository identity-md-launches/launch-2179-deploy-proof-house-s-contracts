// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {MockSeats} from "./mocks/MockSeats.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {HolderGate} from "../src/base/HolderGate.sol";

/// @dev Holders first: identity.md seat or minimum-IMD holders only during the window, then anyone.
contract GateTest is Fixture {
    MockSeats internal seats;
    uint256 internal constant MIN_IMD = 10e18;
    uint64 internal constant WINDOW = 24 hours;
    address internal dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        seats = new MockSeats();
        vm.deal(dave, 1000 ether);
    }

    function _gateFactory() internal {
        vm.prank(curator);
        factory.setGate(address(seats), address(imd), MIN_IMD, WINDOW);
    }

    // ---------- editions ----------

    function test_editions_holdersFirstThenAnyone() public {
        _publishAll();
        _gateFactory();
        _openSale(0.01 ether);
        assertEq(factory.gateEndsAt(), block.timestamp + WINDOW);

        // nobody without IMD or a seat
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        factory.buy{value: 0.01 ether}(address(0));

        // below the minimum is not enough
        imd.mint(alice, MIN_IMD - 1);
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        factory.buyMany{value: 0.02 ether}(2, address(0));

        // at the minimum: in
        imd.mint(alice, 1);
        vm.prank(alice);
        factory.buyMany{value: 0.02 ether}(2, address(0));
        assertEq(factory.mintedBy(alice), 2);

        // after the window: anyone, no IMD or seat needed
        vm.warp(block.timestamp + WINDOW);
        vm.prank(bob);
        factory.buy{value: 0.01 ether}(address(0));
        assertEq(factory.sold(), 3);
    }

    function test_editions_seatBuysUpToFivePerSeatWhereverItGoes() public {
        _publishAll();
        _gateFactory();
        _openSale(0.01 ether);
        seats.mint(bob, 986);

        // a seat holder buys with their seat (no IMD needed)
        vm.prank(bob);
        factory.buyWithSeat{value: 0.03 ether}(986, 3, address(0));
        assertEq(factory.mintedBySeat(986), 3);

        // someone else's seat doesn't count
        vm.prank(carol);
        vm.expectRevert(HolderGate.NotEligible.selector);
        factory.buyWithSeat{value: 0.01 ether}(986, 1, address(0));

        // the seat moves on; its new holder gets only what the seat has left
        vm.prank(bob);
        seats.transferFrom(bob, carol, 986);
        vm.prank(carol);
        vm.expectRevert(ArtifactsFactory.SeatLimit.selector);
        factory.buyWithSeat{value: 0.03 ether}(986, 3, address(0));
        vm.prank(carol);
        factory.buyWithSeat{value: 0.02 ether}(986, 2, address(0));
        assertEq(factory.mintedBySeat(986), 5);

        // a plain buy needs IMD during the window, seat or not
        vm.prank(carol);
        vm.expectRevert(HolderGate.NotEligible.selector);
        factory.buy{value: 0.01 ether}(address(0));

        // after the window buyWithSeat is just buyMany: no seat checks
        vm.warp(block.timestamp + WINDOW);
        vm.prank(dave);
        factory.buyWithSeat{value: 0.01 ether}(1, 1, address(0));
        assertEq(factory.sold(), 6);
    }

    function test_editions_gateFixedOnceTheSaleOpens() public {
        _publishAll();
        _gateFactory();
        _openSale(0.01 ether);
        vm.startPrank(curator);
        vm.expectRevert(ArtifactsFactory.SaleIsOpen.selector);
        factory.setGate(address(0), address(0), 0, 0);
        // closing and reopening doesn't restart the window
        factory.setSaleOpen(false);
        vm.expectRevert(ArtifactsFactory.SaleIsOpen.selector);
        factory.setGate(address(0), address(0), 0, 0);
        vm.warp(block.timestamp + WINDOW);
        factory.setSaleOpen(true);
        vm.stopPrank();
        vm.prank(alice);
        factory.buy{value: 0.01 ether}(address(0)); // the window ran out while the sale was closed
    }

    function test_editions_noGateMeansOpen() public {
        _publishAll();
        _openSale(0.01 ether);
        assertEq(factory.gateEndsAt(), 0);
        vm.prank(alice);
        factory.buy{value: 0.01 ether}(address(0));
    }

    function test_gateRules() public {
        vm.startPrank(curator);
        vm.expectRevert(HolderGate.BadGate.selector);
        factory.setGate(address(0), address(0), 0, WINDOW); // a window nobody could enter
        vm.expectRevert(HolderGate.BadGate.selector);
        factory.setGate(address(seats), address(imd), 0, WINDOW); // a token needs a minimum
        vm.expectRevert(HolderGate.BadGate.selector);
        factory.setGate(address(seats), address(0), 1, WINDOW); // and a minimum needs a token
        vm.expectRevert(HolderGate.BadGate.selector);
        factory.setGate(address(seats), address(imd), MIN_IMD, 31 days);
        factory.setGate(address(seats), address(0), 0, WINDOW); // seats only is fine
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        factory.setGate(address(0), address(0), 0, 0);
    }

    function test_brokenSeatContractCountsAsNotHeld() public {
        _publishAll();
        vm.prank(curator);
        factory.setGate(address(this), address(imd), MIN_IMD, WINDOW); // this test contract has no balanceOf/ownerOf
        _openSale(0.01 ether);
        assertFalse(factory.holdsSeat(alice));
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        factory.buyWithSeat{value: 0.01 ether}(1, 1, address(0));
    }

    // ---------- THE SOURCE ----------

    function _openAuction() internal {
        vm.startPrank(curator);
        source.storeRendererChunk("page");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        source.setGate(address(seats), address(imd), MIN_IMD, WINDOW);
        source.setAuction(1 ether, uint64(block.timestamp + 2 days));
        vm.stopPrank();
    }

    function test_auction_holdersFirstThenAnyone() public {
        _openAuction();
        assertEq(source.gateEndsAt(), block.timestamp + WINDOW);
        vm.prank(alice);
        vm.expectRevert(HolderGate.NotEligible.selector);
        source.bid{value: 1 ether}(address(0));

        seats.mint(bob, 7); // any seat is enough to bid
        vm.prank(bob);
        source.bid{value: 1 ether}(address(0));

        imd.mint(carol, MIN_IMD); // or the IMD minimum
        vm.prank(carol);
        source.bid{value: 1.05 ether}(address(0));

        vm.warp(block.timestamp + WINDOW); // then anyone
        vm.prank(alice);
        source.bid{value: 1.2 ether}(address(0));
        assertEq(source.highBidder(), alice);
    }

    /// @dev Until the first bid the gate can be corrected (a wrong address would shut every holder out of a
    /// holders-only auction, and an auction nobody bid on can only be reopened); from the first bid it is fixed.
    function test_auction_gateFixedFromTheFirstBid() public {
        _openAuction();
        vm.prank(curator);
        source.setGate(address(seats), address(imd), MIN_IMD * 2, WINDOW);
        assertEq(source.gateMinBalance(), MIN_IMD * 2);
        seats.mint(bob, 7);
        vm.prank(bob);
        source.bid{value: 1 ether}(address(0));
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.AuctionLive.selector);
        source.setGate(address(0), address(0), 0, 0);
    }
}
