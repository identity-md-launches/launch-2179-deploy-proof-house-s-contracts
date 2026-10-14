// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVRFCoordinatorV2Plus} from "../../src/interfaces/Interfaces.sol";
import {ArtifactsPiece} from "../../src/ArtifactsPiece.sol";

/// @dev ERC-20 that keeps a 1% fee on every transfer (the balance delta is less than the amount).
contract FeeOnTransferToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount - amount / 100;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - amount / 100;
        return true;
    }
}

/// @dev ERC-20 whose transfers return false instead of reverting.
contract FalseReturningToken {
    mapping(address => uint256) public balanceOf;

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev A coordinator that hands out the same request id twice.
contract DuplicateIdCoordinator {
    function requestRandomWords(IVRFCoordinatorV2Plus.RandomWordsRequest calldata) external pure returns (uint256) {
        return 42;
    }
}

/// @dev A coordinator that reverts (subscription unfunded / consumer not added).
contract RevertingCoordinator {
    function requestRandomWords(IVRFCoordinatorV2Plus.RandomWordsRequest calldata) external pure returns (uint256) {
        revert("InsufficientBalance");
    }
}

/// @dev A coordinator that can be switched to revert (subscription ran dry) and back; sequential ids otherwise.
contract TogglingCoordinator {
    bool public failing;
    uint256 public nextId = 1000;
    mapping(uint256 => address) public consumer;

    function setFailing(bool v) external {
        failing = v;
    }

    function requestRandomWords(IVRFCoordinatorV2Plus.RandomWordsRequest calldata) external returns (uint256 id) {
        if (failing) revert("InsufficientBalance");
        id = nextId++;
        consumer[id] = msg.sender;
    }

    function fulfill(uint256 id, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        (bool ok, bytes memory ret) =
            consumer[id].call(abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", id, words));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @dev An ERC-721 receiver that rejects, and one that accepts and re-enters the piece.
contract RejectingReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

contract ReenteringReceiver {
    ArtifactsPiece public piece;
    bool public listedDuringHook;

    constructor(ArtifactsPiece p) {
        piece = p;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        // now the owner: listing inside the hook is allowed and harmless (state is already settled)
        piece.list(1 ether);
        listedDuringHook = true;
        return this.onERC721Received.selector;
    }
}

/// @dev Minimal controller for a hand-initialised piece clone (to reach paths ArtifactsSource never exposes).
contract StubController {
    bool public payloadLocked;
    address[] internal chunks;

    function setLocked(bool v) external {
        payloadLocked = v;
    }

    function payloadChunks() external view returns (address[] memory) {
        return chunks;
    }
}
