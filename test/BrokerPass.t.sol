// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {BrokerPass} from "../src/BrokerPass.sol";
import {MockSeats} from "./mocks/MockSeats.sol";

/// @dev The Proof House Broker Pass: claims by piece and by seat, the 100 cap, pass holders as brokers on mints,
/// THE SOURCE's no-house split, and broker shares on resales credited in the ledger.
contract BrokerPassTest is Fixture {
    MockSeats internal seats;
    BrokerPass internal pass;
    address internal agent = makeAddr("agent");
    address internal agent2 = makeAddr("agent2");
    address internal constant ETH = address(0);

    function setUp() public override {
        super.setUp();
        seats = new MockSeats();
        pass = new BrokerPass(address(seats), address(factory), address(source));
        vm.startPrank(curator);
        house.setBrokerPass(address(pass));
        pass.setClaimsOpenAt(uint64(block.timestamp));
        vm.stopPrank();
        _publishAll();
        _openSale(1 ether);
    }

    // ---------- claiming ----------

    function test_claimWithSeat_onceEverPerSeat() public {
        seats.mint(agent, 7);
        vm.prank(bob);
        vm.expectRevert(BrokerPass.NotHolder.selector);
        pass.claimWithSeat(7);
        vm.prank(agent);
        assertEq(pass.claimWithSeat(7), 1);
        assertEq(pass.ownerOf(1), agent);
        assertTrue(pass.seatClaimed(7));
        // moving the seat to a fresh wallet does not mint a second pass
        vm.prank(agent);
        seats.transferFrom(agent, agent2, 7);
        vm.prank(agent2);
        vm.expectRevert(BrokerPass.AlreadyClaimed.selector);
        pass.claimWithSeat(7);
    }

    function test_claimWithPiece_onceEverPerPiece() public {
        uint256 edition = _buyAndAssign(alice, address(0), 3);
        // an edition only counts once its own contract exists
        vm.prank(alice);
        vm.expectRevert(BrokerPass.NoSuchPiece.selector);
        pass.claimWithPiece(edition);
        ArtifactsPiece piece = _claim(alice, edition);
        vm.prank(bob);
        vm.expectRevert(BrokerPass.NotHolder.selector);
        pass.claimWithPiece(edition);
        vm.prank(alice);
        pass.claimWithPiece(edition);
        assertEq(pass.balanceOf(alice), 1);
        vm.prank(alice);
        piece.transferFrom(alice, bob, 1);
        vm.prank(bob);
        vm.expectRevert(BrokerPass.AlreadyClaimed.selector);
        pass.claimWithPiece(edition);
        vm.expectRevert(BrokerPass.NoSuchPiece.selector);
        pass.claimWithPiece(0);
        vm.expectRevert(BrokerPass.NoSuchPiece.selector);
        pass.claimWithPiece(257);
    }

    function test_claimsWaitForTheStartTime_setOnceByTheCurator() public {
        BrokerPass fresh = new BrokerPass(address(seats), address(factory), address(source));
        seats.mint(agent, 7);
        vm.prank(agent);
        vm.expectRevert(BrokerPass.ClaimsNotOpen.selector);
        fresh.claimWithSeat(7); // nothing set yet: closed
        vm.prank(agent);
        vm.expectRevert(BrokerPass.NotCurator.selector);
        fresh.setClaimsOpenAt(uint64(block.timestamp));
        vm.prank(curator);
        vm.expectRevert(BrokerPass.BadStart.selector);
        fresh.setClaimsOpenAt(0);
        // a mistyped far-off time would shut claims for good: no more than a year ahead
        vm.prank(curator);
        vm.expectRevert(BrokerPass.BadStart.selector);
        fresh.setClaimsOpenAt(uint64(block.timestamp + 365 days + 1));
        uint64 start = uint64(block.timestamp + 1 days);
        vm.prank(curator);
        fresh.setClaimsOpenAt(start);
        assertEq(fresh.claimsOpenAt(), start);
        assertFalse(fresh.claimsOpen());
        vm.prank(agent);
        vm.expectRevert(BrokerPass.ClaimsNotOpen.selector);
        fresh.claimWithSeat(7); // set, not reached
        // fixed forever: no earlier, no later, not even by the curator
        vm.prank(curator);
        vm.expectRevert(BrokerPass.StartAlreadySet.selector);
        fresh.setClaimsOpenAt(uint64(block.timestamp));
        vm.warp(start);
        assertTrue(fresh.claimsOpen());
        vm.prank(agent);
        assertEq(fresh.claimWithSeat(7), 1);
    }

    function test_oneClaimPerWallet() public {
        seats.mint(agent, 7);
        seats.mint(agent, 8);
        vm.prank(agent);
        uint256 id = pass.claimWithSeat(7);
        assertTrue(pass.walletClaimed(agent));
        vm.prank(agent);
        vm.expectRevert(BrokerPass.WalletAlreadyClaimed.selector);
        pass.claimWithSeat(8);
        // giving the pass away does not free the wallet to claim again
        vm.prank(agent);
        pass.transferFrom(agent, agent2, id);
        vm.prank(agent);
        vm.expectRevert(BrokerPass.WalletAlreadyClaimed.selector);
        pass.claimWithSeat(8);
        // nor does a piece
        ArtifactsPiece piece = _claim(alice, _buyAndAssign(alice, address(0), 3));
        uint256 pieceId = piece.pieceId();
        vm.prank(alice);
        piece.transferFrom(alice, agent, 1);
        vm.prank(agent);
        vm.expectRevert(BrokerPass.WalletAlreadyClaimed.selector);
        pass.claimWithPiece(pieceId);
        // the unused seat still claims, from another wallet
        vm.prank(agent);
        seats.transferFrom(agent, carol, 8);
        vm.prank(carol);
        assertEq(pass.claimWithSeat(8), 2);
        assertFalse(pass.seatClaimed(9));
    }

    function test_claimWithTheSource() public {
        vm.prank(alice);
        vm.expectRevert(BrokerPass.NoSuchPiece.selector);
        pass.claimWithPiece(256); // not sold yet
        _sellSource(bob, address(0), 1 ether);
        vm.prank(bob);
        pass.claimWithPiece(256);
        assertEq(pass.balanceOf(bob), 1);
    }

    function test_capIs100() public {
        for (uint256 i = 1; i <= 100; ++i) {
            address holder = address(uint160(0x10000 + i));
            seats.mint(holder, i);
            vm.prank(holder);
            pass.claimWithSeat(i);
        }
        assertEq(pass.totalSupply(), 100);
        assertEq(pass.remaining(), 0);
        seats.mint(agent, 101);
        vm.prank(agent);
        vm.expectRevert(BrokerPass.AllClaimed.selector);
        pass.claimWithSeat(101);
        assertFalse(pass.seatClaimed(101)); // a refused claim leaves the seat unused
    }

    function test_tokenURIIsOnChainJson() public {
        seats.mint(agent, 1);
        vm.prank(agent);
        pass.claimWithSeat(1);
        string memory uri = pass.tokenURI(1);
        assertEq(_prefix(uri, 29), "data:application/json;base64,");
        vm.expectRevert();
        pass.tokenURI(2);
    }

    // ---------- pass holders as brokers ----------

    function test_passHolderEarnsOnMint_andTheRightMovesWithThePass() public {
        seats.mint(agent, 1);
        vm.prank(agent);
        uint256 id = pass.claimWithSeat(1);
        assertTrue(house.isEligibleBroker(agent));
        assertFalse(house.isEligibleBroker(agent2));

        _buyAndAssign(bob, agent, 5);
        assertEq(house.balances(agent, ETH), 0.15 ether);

        // the pass is transferable; the broker right goes with it
        vm.prank(agent);
        pass.transferFrom(agent, agent2, id);
        assertFalse(house.isEligibleBroker(agent));
        assertTrue(house.isEligibleBroker(agent2));
        uint256 houseBefore = house.balances(address(house), ETH);
        _buyAndAssign(carol, agent, 6); // the old holder earns nothing now
        assertEq(house.balances(agent, ETH), 0.15 ether);
        assertEq(house.balances(address(house), ETH) - houseBefore, 0.05 ether, "house 5%; the unearned 15% burns");
        _buyAndAssign(carol, agent2, 7);
        assertEq(house.balances(agent2, ETH), 0.15 ether);
    }

    /// A pass holder may name themselves as the broker on their own buy: the agent share is a Broker Pass perk.
    /// It comes out of the burn, never the artist: 75% to the artist either way.
    function test_passHolderCanBrokerTheirOwnBuy() public {
        seats.mint(bob, 1);
        vm.prank(bob);
        pass.claimWithSeat(1);
        uint256 artistBefore = house.balances(artist, ETH);
        uint256 burnBefore = house.balances(house.BUYBACK(), ETH);
        _buyAndAssign(bob, bob, 5);
        assertEq(house.balances(bob, ETH), 0.15 ether, "15% back to the pass holder");
        assertEq(house.balances(artist, ETH) - artistBefore, 0.75 ether, "artist 75% either way");
        assertEq(house.balances(house.BUYBACK(), ETH) - burnBefore, 0.05 ether, "only the 5% burns");
    }

    function test_setBrokerPassOnce() public {
        vm.prank(curator);
        vm.expectRevert(ArtHouse.BrokerPassAlreadySet.selector);
        house.setBrokerPass(address(1));
        vm.prank(bob);
        vm.expectRevert();
        house.setBrokerPass(address(1));
    }

    // ---------- THE SOURCE: 85% artist, 15% broker, no house ----------

    function test_sourceSplit_brokerAndArtistOnly() public {
        vm.prank(curator);
        house.setSplit(address(source), 1500, 0, 8500, 0);
        seats.mint(agent, 1);
        vm.prank(agent);
        pass.claimWithSeat(1);
        uint256 artistBefore = house.balances(artist, ETH);
        uint256 houseBefore = house.balances(address(house), ETH);
        _sellSource(bob, agent, 2 ether);
        assertEq(house.balances(agent, ETH), 0.3 ether);
        assertEq(house.balances(artist, ETH) - artistBefore, 1.7 ether);
        assertEq(house.balances(address(house), ETH), houseBefore);
    }

    function test_sourceSplit_noBrokerBurns() public {
        vm.prank(curator);
        house.setSplit(address(source), 1500, 0, 8500, 0);
        uint256 artistBefore = house.balances(artist, ETH);
        uint256 houseBefore = house.balances(address(house), ETH);
        uint256 burnBefore = house.balances(house.BUYBACK(), ETH);
        _sellSource(bob, address(0), 2 ether);
        assertEq(house.balances(artist, ETH) - artistBefore, 1.7 ether, "artist 85 either way");
        assertEq(house.balances(house.BUYBACK(), ETH) - burnBefore, 0.3 ether, "the unclaimed 15 buys back and burns");
        assertEq(house.balances(address(house), ETH), houseBefore);
    }

    // ---------- resales ----------

    function _listAndSell(ArtifactsPiece piece, address seller, address buyer, address broker_, uint256 price) internal {
        vm.prank(seller);
        piece.list(price);
        vm.prank(buyer);
        piece.buy{value: price}(_vk(string(abi.encodePacked("vk", buyer))), broker_);
        _postKey(piece, seller, price / 10);
        vm.prank(buyer);
        piece.release();
    }

    function test_resaleBrokerShare_creditedInTheLedger() public {
        seats.mint(agent, 1);
        vm.prank(agent);
        pass.claimWithSeat(1);
        ArtifactsPiece piece = _claim(alice, _buyAndAssign(alice, address(0), 9));
        uint256 artistBefore = house.balances(artist, ETH);
        _listAndSell(piece, alice, bob, agent, 4 ether);
        assertEq(piece.ownerOf(1), bob);
        assertEq(house.balances(agent, ETH), 0.1 ether); // 2.5%
        assertEq(house.balances(artist, ETH) - artistBefore, 0.3 ether); // 7.5%
        assertEq(piece.pendingWithdrawals(alice), 3.6 ether + 0.4 ether); // 90%, and the deposit back
        assertEq(address(piece).balance, 4 ether);
        vm.prank(agent);
        house.withdraw(ETH);
        assertEq(agent.balance, 0.1 ether);
    }

    function test_resaleWithoutEligibleBroker_sellerKeepsTheShare() public {
        ArtifactsPiece piece = _claim(alice, _buyAndAssign(alice, address(0), 9));
        _listAndSell(piece, alice, bob, agent2, 4 ether); // agent2 holds no pass
        assertEq(house.balances(agent2, ETH), 0);
        assertEq(piece.pendingWithdrawals(alice), 3.7 ether + 0.4 ether); // 92.5%, and the deposit back
    }

    function test_resaleSellerCannotBeBroker() public {
        seats.mint(alice, 1);
        vm.prank(alice);
        pass.claimWithSeat(1);
        ArtifactsPiece piece = _claim(alice, _buyAndAssign(alice, address(0), 9));
        _listAndSell(piece, alice, bob, alice, 4 ether);
        assertEq(house.balances(alice, ETH), 0);
        assertEq(piece.pendingWithdrawals(alice), 3.7 ether + 0.4 ether);
    }

    function test_resaleBuyerWithAPassCanBrokerTheirOwnBuy() public {
        seats.mint(bob, 1);
        vm.prank(bob);
        pass.claimWithSeat(1);
        ArtifactsPiece piece = _claim(alice, _buyAndAssign(alice, address(0), 9));
        uint256 artistBefore = house.balances(artist, ETH);
        _listAndSell(piece, alice, bob, bob, 4 ether);
        assertEq(piece.ownerOf(1), bob);
        assertEq(house.balances(bob, ETH), 0.1 ether, "2.5% back to the buyer's pass");
        assertEq(house.balances(artist, ETH) - artistBefore, 0.3 ether, "royalty 7.5% either way");
        assertEq(piece.pendingWithdrawals(alice), 3.6 ether + 0.4 ether, "seller 90%, and the deposit back");
    }

    function test_resaleFallsBackToThePieceWhenTheLedgerRefuses() public {
        seats.mint(agent, 1);
        vm.prank(agent);
        pass.claimWithSeat(1);
        ArtifactsPiece piece = _claim(alice, _buyAndAssign(alice, address(0), 9));
        vm.prank(curator);
        house.setSaleModule(address(factory), false); // the ledger now refuses this piece's resale credit
        _listAndSell(piece, alice, bob, agent, 4 ether);
        assertEq(piece.ownerOf(1), bob); // the sale still completes
        (address royaltyTo,) = piece.royaltyInfo(1, 4 ether);
        assertEq(piece.pendingWithdrawals(royaltyTo), 0.3 ether);
        assertEq(piece.pendingWithdrawals(agent), 0.1 ether);
        assertEq(piece.pendingWithdrawals(alice), 3.6 ether + 0.4 ether);
        assertEq(address(piece).balance, 4.4 ether);
    }

    function test_recordResaleRejectsAnythingButAPiece() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        house.recordResale{value: 1 ether}(agent, 1 ether, 0);
        FakePiece fake = new FakePiece(address(factory));
        vm.deal(address(fake), 1 ether);
        vm.expectRevert(ArtHouse.NotPiece.selector);
        fake.credit(house);
    }

    // ---------- helpers ----------

    function _sellSource(address winner, address broker_, uint256 amount) internal {
        vm.startPrank(curator);
        source.storeRendererChunk("payload");
        source.lock(SEALED_SEED, SOURCE_COMMITMENT);
        source.setAuction(amount, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        vm.prank(winner);
        source.bid{value: amount}(broker_);
        vm.warp(block.timestamp + 1 days + 1);
        source.settle();
    }

    function _prefix(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; ++i) out[i] = b[i];
        return string(out);
    }
}

/// @dev Claims to be a piece of the factory without being one.
contract FakePiece {
    address public controller;

    constructor(address controller_) {
        controller = controller_;
    }

    function credit(ArtHouse house) external {
        house.recordResale{value: 1 ether}(address(0), 1 ether, 0);
    }
}
