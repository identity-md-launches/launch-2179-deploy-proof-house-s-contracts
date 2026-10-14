// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "../Fixture.sol";
import {ArtifactsSource} from "../../src/ArtifactsSource.sol";
import {ArtifactsPiece} from "../../src/ArtifactsPiece.sol";
import {ArtHouse} from "../../src/ArtHouse.sol";

/// @dev Random bids (around the exact minimum), refunds, time warps, settlement and re-setting of the auction.
contract AuctionHandler is Test {
    ArtifactsSource public source;
    ArtHouse public house;
    address public curator;
    address public broker;
    address[] public actors;

    uint256 public bidIn;
    uint256 public refundOut;
    uint256 public settledAmount;
    uint256 public lastHigh;
    bool public everSettled;
    uint256 public bids;

    constructor(ArtifactsSource s, ArtHouse h, address curator_, address broker_, address[] memory actors_) {
        source = s;
        house = h;
        curator = curator_;
        broker = broker_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _minBid() internal view returns (uint256) {
        uint256 high = source.highBid();
        uint256 reserve = source.reserve();
        // the 5% raise rounds up: the smallest bid that is at least 105% of the high bid
        uint256 raise = high == 0 ? 0 : (high * 10_500 + 9_999) / 10_000;
        return raise > reserve ? raise : reserve;
    }

    function bid(uint256 a, uint256 seed, uint256 brokerSeed) external {
        address actor = actors[a % actors.length];
        uint256 min = _minBid();
        uint256 amount;
        uint256 k = seed % 4;
        if (k == 0) amount = min == 0 ? 0 : min - 1;
        else if (k == 1) amount = min;
        else amount = bound(seed, min, min + 2 ether);
        address b = brokerSeed % 3 == 0 ? address(0) : brokerSeed % 3 == 1 ? broker : actor;
        vm.deal(actor, actor.balance + amount);

        bool open = source.auctionOpen();
        uint64 end = source.endTime();
        uint256 high = source.highBid();
        address prev = source.highBidder();
        // independent of _minBid: a bid is valid iff 10_000 * amount >= 10_500 * high (and it meets the reserve)
        bool ok = open && block.timestamp < end && amount >= source.reserve()
            && (high == 0 || amount * 10_000 >= high * 10_500);
        if (high != 0 && amount <= high) assertFalse(ok, "a bid can never tie or undercut the high bid");
        uint256 prevRefund = prev == address(0) ? 0 : source.refunds(prev);
        vm.prank(actor);
        if (!ok) vm.expectRevert();
        source.bid{value: amount}(b);
        if (ok) {
            bidIn += amount;
            bids++;
            assertEq(source.highBidder(), actor);
            assertEq(source.highBid(), amount);
            assertEq(source.highBroker(), b);
            if (prev != address(0)) assertEq(source.refunds(prev), prevRefund + high, "outbid bid refundable");
            if (end - block.timestamp < 10 minutes) {
                assertEq(source.endTime(), block.timestamp + 10 minutes, "extended by 10 minutes");
            } else {
                assertEq(source.endTime(), end, "no extension outside the final 10 minutes");
            }
        }
    }

    function withdrawRefund(uint256 a) external {
        address actor = actors[a % actors.length];
        uint256 amount = source.refunds(actor);
        uint256 before = actor.balance;
        vm.prank(actor);
        if (amount == 0) vm.expectRevert(ArtifactsSource.NothingToWithdraw.selector);
        source.withdrawRefund();
        if (amount > 0) {
            assertEq(actor.balance - before, amount);
            assertEq(source.refunds(actor), 0);
            refundOut += amount;
        }
    }

    function warp(uint256 delta) external {
        vm.warp(block.timestamp + bound(delta, 1, 30 minutes));
    }

    function settle(uint256 a) external {
        address actor = actors[a % actors.length];
        bool ok = source.auctionOpen() && block.timestamp >= source.endTime() && !source.settled()
            && source.highBidder() != address(0);
        address winner = source.highBidder();
        uint256 high = source.highBid();
        uint256 houseBefore = address(house).balance;
        vm.prank(actor);
        if (!ok) {
            vm.expectRevert();
            source.settle();
            return;
        }
        address piece = source.settle();
        {
            everSettled = true;
            settledAmount = high;
            assertTrue(source.settled());
            assertFalse(source.auctionOpen());
            assertEq(source.pieceContract(), piece);
            assertEq(ArtifactsPiece(piece).ownerOf(1), winner, "THE SOURCE goes to the winner");
            assertTrue(ArtifactsPiece(piece).isSource());
            assertEq(address(house).balance - houseBefore, high, "proceeds through the ledger");
        }
    }

    function setAuction(uint256 reserve, uint256 endDelta, bool asCurator) external {
        reserve = reserve % 5 == 0 ? 0 : bound(reserve, 1, 5 ether);
        uint64 end = uint64(block.timestamp + (endDelta % 3 == 0 ? 0 : bound(endDelta, 1, 2 hours)));
        address caller = asCurator ? curator : actors[endDelta % actors.length];
        bool ok =
            asCurator && !source.settled() && source.highBidder() == address(0) && end > block.timestamp && reserve > 0;
        vm.prank(caller);
        if (!ok) vm.expectRevert();
        source.setAuction(reserve, end);
        if (ok) {
            assertTrue(source.auctionOpen());
            assertEq(source.reserve(), reserve);
            assertEq(source.endTime(), end);
        }
    }

    function payloadStaysLocked(uint256 seed) external {
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.IsLocked.selector);
        source.storePayloadChunk(abi.encodePacked(seed));
        vm.prank(curator);
        vm.expectRevert(ArtifactsSource.IsLocked.selector);
        source.resetPayload();
    }

    function recordHigh() external {
        uint256 high = source.highBid();
        assertGe(high, lastHigh, "high bid never decreases");
        lastHigh = high;
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
contract SourceAuctionInvariantTest is Fixture {
    AuctionHandler internal h;
    address internal dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        vm.startPrank(curator);
        source.storePayloadChunk("payload");
        source.lockPayload();
        source.setAuction(1 ether, uint64(vm.getBlockTimestamp() + 1 hours));
        vm.stopPrank();
        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = dave;
        h = new AuctionHandler(source, house, curator, broker, actors);
        targetContract(address(h));
    }

    /// @dev The auction holds the live high bid plus every refund owed, and nothing else.
    function invariant_auctionConservation() public view {
        uint256 owed;
        for (uint256 i; i < h.actorCount(); ++i) {
            owed += source.refunds(h.actors(i));
        }
        uint256 live = source.settled() ? 0 : source.highBid();
        assertEq(address(source).balance, live + owed, "balance = live bid + refunds owed");
        assertEq(address(source).balance, h.bidIn() - h.refundOut() - h.settledAmount(), "balance = in - out");
    }

    /// @dev Settlement is final: closed, never reopened, the piece exists and the ledger holds the proceeds.
    function invariant_settlementIsFinal() public view {
        if (h.everSettled()) {
            assertTrue(source.settled());
            assertFalse(source.auctionOpen());
            assertTrue(source.pieceContract() != address(0));
            assertEq(ArtifactsPiece(source.pieceContract()).ownerOf(1), source.highBidder());
            assertEq(address(house).balance, h.settledAmount());
            uint256 owed = house.balances(artist, address(0)) + house.balances(broker, address(0))
                + house.balances(address(house), address(0));
            assertEq(owed, h.settledAmount(), "proceeds split in the ledger");
        } else {
            assertEq(source.pieceContract(), address(0));
            assertEq(address(house).balance, 0);
        }
    }

    /// @dev The high bid never goes down, and the bidder holding it is never refunded for it.
    function invariant_highBidMonotone() public view {
        assertGe(source.highBid(), h.lastHigh());
        if (source.highBidder() != address(0)) assertGe(source.highBid(), source.reserve());
        assertTrue(source.payloadLocked());
    }
}
