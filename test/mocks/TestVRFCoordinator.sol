// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVRFCoordinatorV2Plus} from "../../src/interfaces/Interfaces.sol";

interface IVRFConsumerTest {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @notice TEST NETWORKS ONLY. A stand-in for Chainlink's coordinator so a Sepolia rehearsal isn't held up by the
/// testnet VRF service: it records each request, and only its deployer (the test curator's script) answers them,
/// with a random word from outside the chain. Never configure it on mainnet: the answerer chooses the randomness.
contract TestVRFCoordinator {
    address public immutable owner;
    uint256 public nextId = 1;
    mapping(uint256 => address) public consumer;
    mapping(uint256 => bool) public fulfilled;
    // as VRF v2.5: set on request, deleted when answered
    mapping(uint256 => bytes32) public s_requestCommitments;

    event Requested(uint256 indexed requestId, address indexed consumer);

    error NotOwner();
    error Unknown();

    constructor() {
        owner = msg.sender;
    }

    function requestRandomWords(IVRFCoordinatorV2Plus.RandomWordsRequest calldata) external returns (uint256 id) {
        id = nextId++;
        consumer[id] = msg.sender;
        s_requestCommitments[id] = keccak256(abi.encode(id, msg.sender));
        emit Requested(id, msg.sender);
    }

    function fulfill(uint256 id, uint256 word) external {
        if (msg.sender != owner) revert NotOwner();
        if (consumer[id] == address(0) || fulfilled[id]) revert Unknown();
        fulfilled[id] = true;
        delete s_requestCommitments[id];
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        IVRFConsumerTest(consumer[id]).rawFulfillRandomWords(id, words);
    }
}
