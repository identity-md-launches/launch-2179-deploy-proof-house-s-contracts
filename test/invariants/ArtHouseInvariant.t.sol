// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "../Fixture.sol";
import {ArtHouse} from "../../src/ArtHouse.sol";
import {ArtCollection} from "../../src/ArtCollection.sol";
import {MockIMD} from "../mocks/Mocks.sol";

/// @dev Drives the ledger with bounded random inputs from several actors: ETH mints, IMD mints, module sales,
/// withdrawals by every party, split / broker / payout / price / ownership changes. Every call that is expected
/// to succeed must succeed (fail-on-revert); every split is checked exactly against the collection's bps.
contract LedgerHandler is Test {
    ArtHouse public house;
    ArtCollection public col;
    MockIMD public imd;
    address public module; // the approved sale module (ArtifactsFactory), pranked to record module sales
    address public curator;

    address[] public buyers;
    address[] public brokers; // broker candidates; approval toggles
    address[] public artists; // artists[0] owns `col` and the module collection; artists[1] is approved too
    address[] public payouts; // payout candidates for artists[0]
    address[] public owners; // ownership candidates (owners[0] = curator)

    uint256 public constant PIECES = 6;

    // ghosts
    uint256 public ethIn;
    uint256 public ethOut;
    uint256 public imdIn;
    uint256 public imdOut;
    mapping(address => mapping(address => uint256)) public credited;
    mapping(address => mapping(address => uint256)) public withdrawn;
    mapping(uint256 => address) public mintedBy;
    uint256 public mints;
    uint256 public sales;

    constructor(
        ArtHouse house_,
        ArtCollection col_,
        MockIMD imd_,
        address module_,
        address curator_,
        address[] memory buyers_,
        address[] memory brokers_,
        address[] memory artists_,
        address[] memory payouts_,
        address[] memory owners_
    ) {
        house = house_;
        col = col_;
        imd = imd_;
        module = module_;
        curator = curator_;
        buyers = buyers_;
        brokers = brokers_;
        artists = artists_;
        payouts = payouts_;
        owners = owners_;
    }

    // ---------- helpers ----------

    function parties() public view returns (address[] memory p) {
        p = new address[](artists.length + brokers.length + 1);
        uint256 n;
        for (uint256 i; i < artists.length; ++i) {
            p[n++] = artists[i];
        }
        for (uint256 i; i < brokers.length; ++i) {
            p[n++] = brokers[i];
        }
        p[n] = address(house);
    }

    function _pickBroker(uint256 seed, address buyer) internal view returns (address) {
        uint256 k = seed % 5;
        if (k == 0) return address(0);
        if (k == 1) return buyer; // broker is the buyer: no commission
        if (k == 2) return buyers[(seed / 5) % buyers.length]; // a random non-broker
        return brokers[(seed / 5) % brokers.length];
    }

    function _bps(address collection) internal view returns (address artist, uint16 bb, uint16 hb, uint16 ab) {
        (,,,, artist, bb, hb, ab,,,) = house.collections(collection);
    }

    /// @dev Snapshot of every party's balance in `currency`, then the exact split after a sale of `amount`.
    function _balances(address currency) internal view returns (uint256[] memory b) {
        address[] memory p = parties();
        b = new uint256[](p.length);
        for (uint256 i; i < p.length; ++i) {
            b[i] = house.balances(p[i], currency);
        }
    }

    function _checkSplit(
        address collection,
        address buyer,
        address broker,
        address currency,
        uint256 amount,
        uint256[] memory before
    ) internal {
        (address artist, uint16 bb, uint16 hb, uint16 ab) = _bps(collection);
        uint256 artistShare = (amount * ab) / 10_000;
        bool eligible = broker != address(0) && broker != buyer && house.brokers(broker);
        uint256 brokerShare = eligible ? (amount * bb) / 10_000 : 0;
        uint256 houseShare = amount - artistShare - brokerShare;
        assertGe(houseShare, (amount * hb) / 10_000, "house takes rounding");
        address[] memory p = parties();
        for (uint256 i; i < p.length; ++i) {
            uint256 expected;
            if (p[i] == artist) expected += artistShare;
            if (eligible && p[i] == broker) expected += brokerShare;
            if (p[i] == address(house)) expected += houseShare;
            assertEq(house.balances(p[i], currency) - before[i], expected, "split delta");
            credited[p[i]][currency] += expected;
        }
        sales++;
    }

    // ---------- actions ----------

    function mintETH(uint256 buyerSeed, uint256 pieceSeed, uint256 brokerSeed) external {
        address buyer = buyers[buyerSeed % buyers.length];
        uint256 pieceId = pieceSeed % PIECES;
        address b = _pickBroker(brokerSeed, buyer);
        (,, bool open,,,,,,, uint256 priceETH,) = house.collections(address(col));
        if (!open || priceETH == 0 || mintedBy[pieceId] != address(0)) {
            vm.deal(buyer, priceETH);
            vm.prank(buyer);
            vm.expectRevert();
            house.mint{value: priceETH}(address(col), pieceId, b);
            return;
        }
        vm.deal(buyer, priceETH);
        uint256[] memory before = _balances(address(0));
        vm.prank(buyer);
        house.mint{value: priceETH}(address(col), pieceId, b);
        mintedBy[pieceId] = buyer;
        mints++;
        ethIn += priceETH;
        assertEq(col.ownerOf(pieceId), buyer, "minted to buyer");
        _checkSplit(address(col), buyer, b, address(0), priceETH, before);
    }

    function mintIMD(uint256 buyerSeed, uint256 pieceSeed, uint256 brokerSeed) external {
        address buyer = buyers[buyerSeed % buyers.length];
        uint256 pieceId = pieceSeed % PIECES;
        address b = _pickBroker(brokerSeed, buyer);
        (,, bool open,,,,,,,, uint256 priceIMD) = house.collections(address(col));
        if (!open || priceIMD == 0 || mintedBy[pieceId] != address(0)) {
            vm.prank(buyer);
            vm.expectRevert();
            house.mintWithIMD(address(col), pieceId, b, priceIMD);
            return;
        }
        imd.mint(buyer, priceIMD);
        vm.prank(buyer);
        imd.approve(address(house), priceIMD);
        uint256[] memory before = _balances(address(imd));
        uint256 buyerBefore = imd.balanceOf(buyer);
        vm.prank(buyer);
        house.mintWithIMD(address(col), pieceId, b, priceIMD);
        assertEq(buyerBefore - imd.balanceOf(buyer), priceIMD, "pulls exactly the price");
        mintedBy[pieceId] = buyer;
        mints++;
        imdIn += priceIMD;
        assertEq(col.ownerOf(pieceId), buyer, "minted to buyer");
        _checkSplit(address(col), buyer, b, address(imd), priceIMD, before);
    }

    /// @dev An approved module records an ETH sale of its own (module) collection.
    function moduleSale(uint256 buyerSeed, uint256 brokerSeed, uint256 amount) external {
        address buyer = buyers[buyerSeed % buyers.length];
        address b = _pickBroker(brokerSeed, buyer);
        amount = bound(amount, 1, 100 ether);
        vm.deal(module, amount);
        uint256[] memory before = _balances(address(0));
        vm.prank(module);
        house.recordSale{value: amount}(module, buyer, b);
        ethIn += amount;
        _checkSplit(module, buyer, b, address(0), amount, before);
    }

    function withdraw(uint256 partySeed, bool eth) external {
        address[] memory p = parties();
        address party = p[partySeed % (p.length - 1)]; // artists and brokers, not the house
        address currency = eth ? address(0) : address(imd);
        uint256 amount = house.balances(party, currency);
        if (amount == 0) {
            vm.prank(party);
            vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
            house.withdraw(currency);
            return;
        }
        address to = house.artistPayout(party);
        if (to == address(0)) to = party;
        uint256 toBefore = eth ? to.balance : imd.balanceOf(to);
        vm.prank(party);
        house.withdraw(currency);
        uint256 toAfter = eth ? to.balance : imd.balanceOf(to);
        assertEq(toAfter - toBefore, amount, "withdraw pays exactly the balance");
        assertEq(house.balances(party, currency), 0, "balance cleared");
        withdrawn[party][currency] += amount;
        if (eth) ethOut += amount;
        else imdOut += amount;
    }

    function withdrawHouse(bool eth) external {
        address currency = eth ? address(0) : address(imd);
        address owner = house.owner();
        uint256 amount = house.balances(address(house), currency);
        if (amount == 0) {
            vm.prank(owner);
            vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
            house.withdrawHouse(currency);
            return;
        }
        uint256 toBefore = eth ? owner.balance : imd.balanceOf(owner);
        vm.prank(owner);
        house.withdrawHouse(currency);
        uint256 toAfter = eth ? owner.balance : imd.balanceOf(owner);
        assertEq(toAfter - toBefore, amount, "house pays the current owner");
        withdrawn[address(house)][currency] += amount;
        if (eth) ethOut += amount;
        else imdOut += amount;
    }

    function setSplit(bool onModule, uint16 bb, uint16 hb) external {
        bb = uint16(bound(bb, 0, 10_000));
        hb = uint16(bound(hb, 0, 10_000 - bb));
        uint16 ab = 10_000 - bb - hb;
        vm.prank(house.owner());
        house.setSplit(onModule ? module : address(col), bb, hb, ab);
    }

    function setBroker(uint256 seed, bool approved) external {
        vm.prank(house.owner());
        house.setBroker(brokers[seed % brokers.length], approved);
    }

    function setPayout(uint256 seed) external {
        vm.prank(artists[0]);
        house.setPayout(payouts[seed % payouts.length]);
    }

    function setPrices(uint96 priceETH, uint96 priceIMD) external {
        vm.prank(house.owner());
        house.setPrices(address(col), priceETH, priceIMD);
    }

    function setSaleOpen(bool open) external {
        vm.prank(house.owner());
        house.setSaleOpen(address(col), open);
    }

    function handOver(uint256 seed) external {
        address next = owners[seed % owners.length];
        address current = house.owner();
        vm.prank(current);
        house.transferOwnership(next);
        assertEq(house.owner(), current, "two-step: unchanged until accepted");
        vm.prank(next);
        house.acceptOwnership();
        assertEq(house.owner(), next);
    }

    /// @dev Nobody but the owner may call the curator functions; nobody but a module may record sales.
    function strangerCalls(uint256 seed) external {
        address stranger = buyers[seed % buyers.length];
        vm.startPrank(stranger);
        vm.expectRevert();
        house.withdrawHouse(address(0));
        vm.expectRevert();
        house.setSplit(address(col), 0, 0, 10_000);
        vm.expectRevert();
        house.setBroker(stranger, true);
        vm.deal(stranger, 1 ether);
        vm.expectRevert(ArtHouse.NotSaleModule.selector);
        house.recordSale{value: 1 ether}(module, stranger, address(0));
        vm.stopPrank();
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = true
contract ArtHouseInvariantTest is Fixture {
    LedgerHandler internal h;
    ArtCollection internal col;
    address internal artist2 = makeAddr("artist2");
    address internal broker2 = makeAddr("broker2");

    function setUp() public override {
        super.setUp();
        vm.startPrank(curator);
        house.approveArtist(artist2, "Second");
        house.setBroker(broker2, true);
        col = ArtCollection(house.createCollection("Plain", "PLN", artist));
        vm.stopPrank();
        bytes memory svg = bytes('<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>');
        vm.startPrank(artist);
        for (uint256 i; i < 6; ++i) {
            house.registerPiece(address(col), i, keccak256(svg), "P", "D");
            house.uploadChunk(address(col), i, 0, svg);
            house.finalizePiece(address(col), i);
        }
        vm.stopPrank();
        vm.startPrank(curator);
        house.sealCollection(address(col));
        house.setPrices(address(col), 1 ether, 100e18);
        house.setSaleOpen(address(col), true);
        vm.stopPrank();

        address[] memory buyers = new address[](3);
        buyers[0] = alice;
        buyers[1] = bob;
        buyers[2] = carol;
        address[] memory brokers = new address[](2);
        brokers[0] = broker;
        brokers[1] = broker2;
        address[] memory artists = new address[](2);
        artists[0] = artist;
        artists[1] = artist2;
        address[] memory payouts = new address[](3);
        payouts[0] = artist;
        payouts[1] = makeAddr("payoutA");
        payouts[2] = makeAddr("payoutB");
        address[] memory owners = new address[](2);
        owners[0] = curator;
        owners[1] = makeAddr("curator2");
        h = new LedgerHandler(house, col, imd, address(factory), curator, buyers, brokers, artists, payouts, owners);
        targetContract(address(h));
    }

    function _sum(address currency) internal view returns (uint256 total) {
        address[] memory p = h.parties();
        for (uint256 i; i < p.length; ++i) {
            total += house.balances(p[i], currency);
        }
    }

    /// @dev The ETH the ledger holds is exactly what it owes, and exactly what came in minus what went out.
    function invariant_ethConservation() public view {
        assertEq(address(house).balance, h.ethIn() - h.ethOut(), "eth in/out");
        assertEq(address(house).balance, _sum(address(0)), "eth owed");
    }

    function invariant_imdConservation() public view {
        assertEq(imd.balanceOf(address(house)), h.imdIn() - h.imdOut(), "imd in/out");
        assertEq(imd.balanceOf(address(house)), _sum(address(imd)), "imd owed");
    }

    /// @dev Nobody withdraws more than they were credited, in either currency.
    function invariant_noOverWithdrawal() public view {
        address[] memory p = h.parties();
        for (uint256 i; i < p.length; ++i) {
            assertLe(h.withdrawn(p[i], address(0)), h.credited(p[i], address(0)), "eth over-withdrawal");
            assertLe(h.withdrawn(p[i], address(imd)), h.credited(p[i], address(imd)), "imd over-withdrawal");
            assertEq(
                h.credited(p[i], address(0)) - h.withdrawn(p[i], address(0)),
                house.balances(p[i], address(0)),
                "eth balance = credited - withdrawn"
            );
            assertEq(
                h.credited(p[i], address(imd)) - h.withdrawn(p[i], address(imd)),
                house.balances(p[i], address(imd)),
                "imd balance = credited - withdrawn"
            );
        }
    }

    /// @dev Supply is the registered pieces; a minted piece stays with its buyer; the seal never lifts.
    function invariant_supplyAndSeal() public view {
        (,,, bool isSealed,,,,, uint256 pieceCount,,) = house.collections(address(col));
        assertTrue(isSealed, "sealed forever");
        assertEq(pieceCount, 6, "supply fixed");
        uint256 minted;
        for (uint256 i; i < 6; ++i) {
            address by = h.mintedBy(i);
            if (by != address(0)) {
                minted++;
                assertEq(col.ownerOf(i), by, "owner is buyer");
                (,,,, bool wasMinted,) = house.pieces(address(col), i);
                assertTrue(wasMinted);
            } else {
                (bool ok,) = address(col).staticcall(abi.encodeWithSignature("ownerOf(uint256)", i));
                assertFalse(ok, "unminted piece has no owner");
            }
        }
        assertEq(minted, h.mints());
        assertLe(minted, 6);
    }

    /// @dev The ledger's split constants and royalty never change.
    function invariant_constants() public view {
        assertEq(house.ROYALTY_BPS(), 750);
        (address to, uint256 amt) = col.royaltyInfo(0, 1 ether);
        assertEq(to, house.artistPayout(artist));
        assertEq(amt, 0.075 ether);
    }
}
