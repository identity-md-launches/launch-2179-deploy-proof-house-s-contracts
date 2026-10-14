// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "../Fixture.sol";
import {ArtifactsFactory} from "../../src/ArtifactsFactory.sol";
import {ArtifactsPiece} from "../../src/ArtifactsPiece.sol";
import {ArtHouse} from "../../src/ArtHouse.sol";
import {MockVRFCoordinator} from "../mocks/Mocks.sol";
import {Traits} from "../../src/interfaces/Interfaces.sol";

/// @dev Random sequences of purchases, VRF fulfilments (any word), replayed fulfilments, claims and sale toggles.
contract FactoryHandler is Test {
    ArtifactsFactory public factory;
    MockVRFCoordinator public vrf;
    ArtHouse public house;
    address public curator;
    address public broker;
    address[] public buyers;

    uint256[] public pending; // requested, not yet fulfilled
    uint256[] public fulfilled;
    uint256[] public assignedEditions;
    mapping(uint256 => address) public requestBuyer;
    mapping(uint256 => bool) public seen;
    uint256 public seenCount;
    uint256 public paid;
    uint256 public claims;
    uint256 public rerequests;

    constructor(
        ArtifactsFactory f,
        MockVRFCoordinator v,
        ArtHouse h,
        address curator_,
        address broker_,
        address[] memory buyers_
    ) {
        factory = f;
        vrf = v;
        house = h;
        curator = curator_;
        broker = broker_;
        buyers = buyers_;
    }

    function pendingCount() external view returns (uint256) {
        return pending.length;
    }

    function assignedCount() external view returns (uint256) {
        return assignedEditions.length;
    }

    function buy(uint256 buyerSeed, uint256 brokerSeed, bool exactPrice) external {
        address buyer = buyers[buyerSeed % buyers.length];
        uint256 k = brokerSeed % 3;
        address b = k == 0 ? address(0) : k == 1 ? broker : buyer;
        uint256 price = factory.price();
        uint256 value = exactPrice ? price : (brokerSeed % 2 == 0 ? price - 1 : price + 1);
        vm.deal(buyer, value);
        bool ok = factory.saleOpen() && exactPrice && factory.sold() < factory.EDITIONS();
        if (!ok) {
            vm.prank(buyer);
            vm.expectRevert();
            factory.buy{value: value}(b);
            return;
        }
        uint256 soldBefore = factory.sold();
        vm.prank(buyer);
        uint256 id = factory.buy{value: value}(b);
        assertEq(factory.sold(), soldBefore + 1);
        assertEq(factory.requestBuyer(id), buyer);
        assertEq(factory.requestEdition(id), 0, "not yet assigned");
        pending.push(id);
        requestBuyer[id] = buyer;
        paid += price;
    }

    function fulfil(uint256 idx, uint256 word) external {
        if (pending.length == 0) return;
        idx %= pending.length;
        uint256 id = pending[idx];
        pending[idx] = pending[pending.length - 1];
        pending.pop();
        uint256 assignedBefore = factory.assigned();
        vrf.fulfill(id, word);
        uint256 e = factory.requestEdition(id);
        assertTrue(e >= 1 && e <= 255, "edition out of range");
        assertFalse(seen[e], "edition assigned twice");
        seen[e] = true;
        seenCount++;
        assertEq(factory.assigned(), assignedBefore + 1);
        assertEq(factory.editionBuyer(e), requestBuyer[id], "edition goes to the request's buyer");
        assignedEditions.push(e);
        fulfilled.push(id);
    }

    /// @dev The curator re-requests a pending purchase: too early it is refused unchanged; after the window the
    /// old id is dead and the new one carries the same buyer, so the purchase stays exactly one pending request.
    function rerequest(uint256 idx, bool wait) external {
        if (pending.length == 0) return;
        idx %= pending.length;
        uint256 id = pending[idx];
        address buyer = requestBuyer[id];
        uint256 due = factory.requestBlock(id) + factory.VRF_RETRY_BLOCKS();
        if (wait && vm.getBlockNumber() < due) vm.roll(due);
        bool ok = vm.getBlockNumber() >= due;
        vm.prank(curator);
        if (!ok) vm.expectRevert(ArtifactsFactory.RequestTooRecent.selector);
        uint256 newId = factory.rerequestRandomness(id);
        if (!ok) {
            assertEq(factory.requestBuyer(id), buyer, "refused re-request changes nothing");
            return;
        }
        assertTrue(newId != id);
        assertEq(factory.requestBuyer(id), address(0), "old id forgotten");
        assertEq(factory.requestBuyer(newId), buyer, "same buyer");
        assertEq(factory.requestEdition(newId), 0);
        vm.expectRevert(ArtifactsFactory.UnknownRequest.selector);
        vrf.fulfill(id, idx);
        pending[idx] = newId;
        requestBuyer[newId] = buyer;
        rerequests++;
    }

    function strangerRerequest(uint256 idx) external {
        if (pending.length == 0) return;
        uint256 id = pending[idx % pending.length];
        vm.roll(vm.getBlockNumber() + factory.VRF_RETRY_BLOCKS());
        vm.prank(buyers[idx % buyers.length]);
        vm.expectRevert();
        factory.rerequestRandomness(id);
        assertEq(factory.requestBuyer(id), requestBuyer[id]);
    }

    function replay(uint256 idx, uint256 word) external {
        if (fulfilled.length == 0) return;
        uint256 id = fulfilled[idx % fulfilled.length];
        vm.expectRevert(ArtifactsFactory.AlreadyFulfilled.selector);
        vrf.fulfill(id, word);
    }

    function strangerFulfil(uint256 seed, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.prank(buyers[seed % buyers.length]);
        vm.expectRevert(ArtifactsFactory.NotCoordinator.selector);
        factory.rawFulfillRandomWords(seed, words);
    }

    function claim(uint256 seed, bool byCurator) external {
        if (assignedEditions.length == 0) return;
        uint256 e = assignedEditions[seed % assignedEditions.length];
        address buyer = factory.editionBuyer(e);
        if (factory.pieceContract(e) != address(0)) {
            vm.prank(buyer);
            vm.expectRevert(ArtifactsFactory.AlreadyClaimed.selector);
            factory.claim(e);
            return;
        }
        // a stranger can never claim
        address stranger = buyers[(seed / 7) % buyers.length];
        if (stranger != buyer) {
            vm.prank(stranger);
            vm.expectRevert(ArtifactsFactory.NotBuyer.selector);
            factory.claim(e);
        }
        if (factory.viewingKeyOf(buyer) == bytes32(0)) {
            vm.prank(buyer);
            factory.registerViewingKey(keccak256(abi.encodePacked("vk", buyer)));
        }
        if (factory.wrappedKeyOf(e).length == 0) {
            vm.prank(curator);
            factory.postWrappedKey(e, abi.encodePacked("wrapped", e));
        }
        vm.prank(byCurator ? curator : buyer);
        address piece = factory.claim(e);
        assertEq(factory.pieceContract(e), piece);
        assertEq(ArtifactsPiece(piece).ownerOf(1), buyer, "token minted to the buyer");
        assertEq(ArtifactsPiece(piece).balanceOf(buyer), 1);
        assertEq(ArtifactsPiece(piece).commitment(), factory.commitmentOf(e));
        assertEq(ArtifactsPiece(piece).ciphertextPointer(), factory.ciphertextPointer(e));
        claims++;
    }

    function toggleSale(bool open) external {
        vm.prank(curator);
        factory.setSaleOpen(open);
    }

    function setPrice(uint96 p) external {
        p = uint96(bound(p, 1, 10 ether));
        bool open = factory.saleOpen();
        vm.prank(curator);
        if (open) vm.expectRevert(ArtifactsFactory.SaleIsOpen.selector);
        factory.setPrice(p);
        if (!open) assertEq(factory.price(), p);
    }

    function lockedForever(uint256 seed) external {
        Traits memory t = factory.traitsOf(1);
        vm.prank(curator);
        vm.expectRevert(ArtifactsFactory.IsLocked.selector);
        factory.setPiece(1 + seed % 255, t, "x", keccak256("x"));
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
contract ArtifactsFactoryInvariantTest is Fixture {
    FactoryHandler internal h;

    function setUp() public override {
        super.setUp();
        _publishAll();
        _openSale(0.5 ether);
        address[] memory buyers = new address[](3);
        buyers[0] = alice;
        buyers[1] = bob;
        buyers[2] = carol;
        h = new FactoryHandler(factory, vrf, house, curator, broker, buyers);
        targetContract(address(h));
    }

    /// @dev assigned <= sold <= 255, remaining is what is unsold, every assignment is unique.
    function invariant_counts() public view {
        assertLe(factory.assigned(), factory.sold());
        assertLe(factory.sold(), 255);
        assertEq(factory.remaining(), 255 - factory.sold());
        assertEq(factory.assigned(), h.seenCount());
        assertEq(factory.assigned() + h.pendingCount(), factory.sold(), "every purchase is pending or assigned");
        // re-requests never create purchases or editions: every pending id still maps to its buyer, unassigned
        for (uint256 i; i < h.pendingCount(); ++i) {
            uint256 id = h.pending(i);
            assertEq(factory.requestBuyer(id), h.requestBuyer(id));
            assertEq(factory.requestEdition(id), 0);
        }
    }

    /// @dev Every purchase's ETH sits in the ledger, split and owed to artist / broker / house.
    function invariant_ledgerHoldsEveryPurchase() public view {
        assertEq(address(house).balance, h.paid());
        assertEq(address(factory).balance, 0, "factory never keeps ETH");
        uint256 owed = house.balances(artist, address(0)) + house.balances(broker, address(0))
            + house.balances(address(house), address(0));
        assertEq(owed, h.paid());
    }

    /// @dev A claimed edition's token belongs to its buyer and carries the published commitment and ciphertext.
    function invariant_claimedPiecesBelongToBuyers() public view {
        uint256 n = h.assignedCount();
        uint256 claimed;
        for (uint256 i; i < n; ++i) {
            uint256 e = h.assignedEditions(i);
            address buyer = factory.editionBuyer(e);
            assertTrue(buyer != address(0));
            address piece = factory.pieceContract(e);
            if (piece != address(0)) {
                claimed++;
                assertEq(ArtifactsPiece(piece).ownerOf(1), buyer);
                assertEq(ArtifactsPiece(piece).pieceId(), e);
                assertFalse(ArtifactsPiece(piece).isSource());
            }
        }
        assertEq(claimed, h.claims());
    }

    /// @dev Publication is locked forever; price stays above zero.
    function invariant_lockedAndPriced() public view {
        assertTrue(factory.locked());
        assertEq(factory.piecesSet(), 255);
        assertGt(factory.price(), 0);
    }
}
