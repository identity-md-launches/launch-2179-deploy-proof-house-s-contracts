// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArtStorage} from "../src/ArtStorage.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSource} from "../src/ArtifactsSource.sol";
import {Traits} from "../src/interfaces/Interfaces.sol";
import {MockIMD, MockVRFCoordinator} from "./mocks/Mocks.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// @dev Deploys the launch set exactly as the deploy script does, with mocks for IMD and the VRF coordinator.
abstract contract Fixture is Test {
    address internal curator = makeAddr("curator");
    address internal artist = makeAddr("artist");
    address internal broker = makeAddr("broker");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    MockIMD internal imd;
    MockVRFCoordinator internal vrf;
    ArtStorage internal store;
    ArtHouse internal house;
    ArtifactsPiece internal pieceImpl;
    ArtifactsFactory internal factory;
    ArtifactsSource internal source;

    bytes32 internal constant KEY_HASH = keccak256("keyhash");
    uint256 internal constant SUB_ID = 777;

    function setUp() public virtual {
        imd = new MockIMD();
        vrf = new MockVRFCoordinator();
        Deploy.Deployed memory d = new Deploy().deploy(curator, address(imd));
        store = d.artStorage;
        house = d.artHouse;
        pieceImpl = d.artifactsPiece;
        factory = d.artifactsFactory;
        source = d.artifactsSource;

        // after-launch curator steps
        vm.startPrank(curator);
        store.setHouse(address(house));
        house.approveArtist(artist, "Myles");
        house.setBroker(broker, true);
        house.setSaleModule(address(factory), true);
        house.setSaleModule(address(source), true);
        house.registerModuleCollection(address(factory), artist);
        house.registerModuleCollection(address(source), artist);
        factory.configureVRF(address(vrf), KEY_HASH, SUB_ID, false);
        vm.stopPrank();

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
    }

    function _traits(uint256 id) internal pure returns (Traits memory) {
        // piece 3 matches the reference framed-003.svg (DRIFT / PRISM 3C HORIZONTAL); others vary the title
        return Traits({title: id == 3 ? "DRIFT" : "FLUX", palette: "PRISM", colourCount: 3, direction: "HORIZONTAL"});
    }

    function _publishAll() internal {
        vm.startPrank(curator);
        for (uint256 i = 1; i <= 255; ++i) {
            factory.setPiece(i, _traits(i), abi.encodePacked("ciphertext", i), keccak256(abi.encodePacked("K", i)));
        }
        factory.lock();
        vm.stopPrank();
    }

    function _openSale(uint256 price) internal {
        vm.startPrank(curator);
        factory.setPrice(price);
        factory.setSaleOpen(true);
        vm.stopPrank();
    }

    /// @dev buy as `buyer` with `broker_` and fulfil VRF with `word`; returns the edition assigned.
    function _buyAndAssign(address buyer, address broker_, uint256 word) internal returns (uint256 edition) {
        uint256 p = factory.price();
        vm.prank(buyer);
        uint256 id = factory.buy{value: p}(broker_);
        vrf.fulfill(id, word);
        edition = factory.requestEdition(id);
    }

    function _claim(address buyer, uint256 edition) internal returns (ArtifactsPiece piece) {
        vm.prank(buyer);
        factory.registerViewingKey(keccak256(abi.encodePacked("vk", buyer)));
        vm.prank(curator);
        factory.postWrappedKey(edition, abi.encodePacked("wrapped", edition));
        vm.prank(buyer);
        piece = ArtifactsPiece(factory.claim(edition));
    }
}
