// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVRFCoordinatorV2Plus} from "../../src/interfaces/Interfaces.sol";

/// @dev Plain ERC-20 standing in for IMD in tests. Production randomness and tokens are not these mocks.
contract MockIMD {
    string public name = "IMD";
    string public symbol = "IMD";
    uint8 public decimals = 18;
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
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @dev Records VRF v2.5 requests; tests fulfil them explicitly. Demonstrates local behaviour only.
contract MockVRFCoordinator {
    uint256 public nextId = 1;
    mapping(uint256 => address) public consumer;
    IVRFCoordinatorV2Plus.RandomWordsRequest public lastRequest;

    function requestRandomWords(IVRFCoordinatorV2Plus.RandomWordsRequest calldata req) external returns (uint256 id) {
        id = nextId++;
        consumer[id] = msg.sender;
        lastRequest = req;
    }

    function fulfill(uint256 id, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        IVRFConsumer(consumer[id]).rawFulfillRandomWords(id, words);
    }
}

/// @dev Re-enters the target on receiving ETH.
contract Reenterer {
    address public target;
    bytes public data;
    uint256 public attempts;
    bool public reentryFailed;

    function set(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function call(address to, uint256 value, bytes calldata payload) external payable {
        (bool ok, bytes memory ret) = to.call{value: value}(payload);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    receive() external payable {
        if (attempts == 0 && target != address(0)) {
            attempts++;
            (bool ok,) = target.call(data);
            reentryFailed = !ok;
        }
    }
}
