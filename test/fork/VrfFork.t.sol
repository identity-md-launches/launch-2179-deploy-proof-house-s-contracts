// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {ArtHouse} from "../../src/ArtHouse.sol";
import {ArtifactsFactory} from "../../src/ArtifactsFactory.sol";
import {Traits} from "../../src/interfaces/Interfaces.sol";

interface IVRFCoordinatorV2_5 {
    function createSubscription() external returns (uint256 subId);
    function fundSubscriptionWithNative(uint256 subId) external payable;
    function addConsumer(uint256 subId, address consumer) external;
    function getSubscription(uint256 subId)
        external
        view
        returns (uint96 balance, uint96 nativeBalance, uint64 reqCount, address owner, address[] memory consumers);
    function s_provingKeys(bytes32 keyHash) external view returns (bool exists, uint64 maxGas);
}

/// @dev ArtifactsFactory against Chainlink's real VRF v2.5 coordinator on an Ethereum mainnet fork: a real
/// subscription, funded in ETH, with the factory as its consumer; real requests from real mints. The random words are
/// then delivered the way the coordinator delivers them (rawFulfillRandomWords, from the coordinator's address): a
/// fork can't produce Chainlink's proof, which only their oracle's key can sign. Runs only with FORK_URL set:
///   FORK_URL=<mainnet rpc> forge test --match-path test/fork/VrfFork.t.sol -vv
contract VrfForkTest is Test {
    // Chainlink VRF v2.5 on Ethereum mainnet (docs.chain.link/vrf/v2-5/supported-networks)
    IVRFCoordinatorV2_5 internal constant COORD = IVRFCoordinatorV2_5(0xD7f86b4b8Cae7D942340FF628F82735b7a20893a);
    bytes32 internal constant KEY_HASH_200_GWEI = 0x8077df514608a09f83e4e8d300645594e5d7234665448ba83f51a50f842bd3d9;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint32 internal constant CALLBACK_GAS = 300_000; // what we'd set on mainnet: a draw measured ~176k

    address internal curator = makeAddr("curator");
    address internal artist = makeAddr("artist");
    address internal buyer = makeAddr("buyer");
    ArtHouse internal house;
    ArtifactsFactory internal factory;
    uint256 internal subId;

    function setUp() public {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        Deploy.Deployed memory d = new Deploy().deploy(curator, IMD);
        house = d.artHouse;
        factory = d.artifactsFactory;
        vm.deal(curator, 10 ether);
        vm.deal(buyer, 10 ether);

        vm.startPrank(curator);
        house.approveArtist(artist, "Myles Daughtry");
        house.setSaleModule(address(factory), true);
        house.registerModuleCollection(address(factory), artist);
        // the real subscription: created, funded in ETH, the factory added as its consumer
        subId = COORD.createSubscription();
        COORD.fundSubscriptionWithNative{value: 0.5 ether}(subId);
        COORD.addConsumer(subId, address(factory));
        factory.configureVRF(address(COORD), KEY_HASH_200_GWEI, subId, true);
        factory.setVRFCallbackGas(CALLBACK_GAS);
        for (uint256 i = 1; i <= 255; ++i) {
            factory.setPiece(
                i,
                Traits({title: "FLUX", palette: "PRISM", colourCount: 3, direction: "HORIZONTAL"}),
                abi.encodePacked("ciphertext", i),
                keccak256(abi.encodePacked("K", i))
            );
        }
        factory.lock();
        factory.setPrice(0.01 ether);
        factory.setSaleOpen(true);
        vm.stopPrank();
    }

    function test_fork_theGasLaneExists() public view {
        (bool exists, uint64 maxGas) = COORD.s_provingKeys(KEY_HASH_200_GWEI);
        assertTrue(exists, "the 200 gwei key hash is registered on the coordinator");
        console2.log("200 gwei lane max gas price (gwei):", uint256(maxGas) / 1e9);
    }

    function test_fork_realCoordinatorTakesOurRequests_andTheCallbackFits() public {
        vm.recordLogs();
        vm.prank(buyer);
        uint256[] memory ids = factory.buyMany{value: 0.05 ether}(5, address(0));
        assertEq(ids.length, 5);

        // the coordinator itself logged each request, with our gas lane, subscription and callback limit
        bytes32 requested =
            keccak256("RandomWordsRequested(bytes32,uint256,uint256,uint256,uint16,uint32,uint32,bytes,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(COORD) || logs[i].topics[0] != requested) continue;
            assertEq(logs[i].topics[1], KEY_HASH_200_GWEI, "gas lane");
            assertEq(uint256(logs[i].topics[2]), subId, "subscription");
            (,, uint16 confirmations, uint32 callbackGasLimit, uint32 numWords,) =
                abi.decode(logs[i].data, (uint256, uint256, uint16, uint32, uint32, bytes));
            assertEq(confirmations, 3);
            assertEq(callbackGasLimit, CALLBACK_GAS);
            assertEq(numWords, 1);
            ++seen;
        }
        assertEq(seen, 5, "five requests, one per edition");
        (,, uint64 reqCount,, address[] memory consumers) = COORD.getSubscription(subId);
        assertEq(consumers[0], address(factory));
        console2.log("requests counted on the subscription:", reqCount);

        // Chainlink delivers: each draw from the coordinator's address, inside the callback gas limit
        uint256 most;
        for (uint256 i; i < ids.length; ++i) {
            uint256[] memory words = new uint256[](1);
            words[0] = uint256(keccak256(abi.encode("word", i)));
            vm.prank(address(COORD));
            uint256 g = gasleft();
            factory.rawFulfillRandomWords{gas: CALLBACK_GAS}(ids[i], words);
            uint256 used = g - gasleft();
            if (used > most) most = used;
            assertGt(factory.requestEdition(ids[i]), 0, "an edition was drawn");
        }
        assertEq(factory.assigned(), 5);
        console2.log("most gas one draw used:", most);
        assertLt(most, CALLBACK_GAS, "every draw fits the callback limit");

        // only the coordinator can deliver
        vm.prank(buyer);
        vm.expectRevert();
        factory.rawFulfillRandomWords(ids[0], new uint256[](1));
    }
}
