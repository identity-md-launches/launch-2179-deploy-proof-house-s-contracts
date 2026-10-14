// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TwoStepOwnable} from "./base/TwoStepOwnable.sol";
import {SSTORE2} from "./libs/SSTORE2.sol";

/// @notice SSTORE2 chunk store for plain SVG collections. Only ArtHouse may write, after the owner's one-time setHouse.
contract ArtStorage is TwoStepOwnable {
    address public house;

    // collection => pieceId => chunk pointers
    mapping(address => mapping(uint256 => address[])) private _chunks;

    event HouseSet(address indexed house);
    event ChunkWritten(
        address indexed collection, uint256 indexed pieceId, uint256 index, address pointer, uint256 size
    );
    event PieceCleared(address indexed collection, uint256 indexed pieceId);

    error HouseAlreadySet();
    error NotHouse();
    error BadIndex();

    constructor(address owner_) TwoStepOwnable(owner_) {}

    function setHouse(address house_) external onlyOwner {
        if (house != address(0)) revert HouseAlreadySet();
        if (house_ == address(0)) revert ZeroAddress();
        house = house_;
        emit HouseSet(house_);
    }

    modifier onlyHouse() {
        if (msg.sender != house) revert NotHouse();
        _;
    }

    function write(address collection, uint256 pieceId, uint256 index, bytes calldata data)
        external
        onlyHouse
        returns (address pointer)
    {
        address[] storage list = _chunks[collection][pieceId];
        if (index != list.length) revert BadIndex();
        pointer = SSTORE2.write(data);
        list.push(pointer);
        emit ChunkWritten(collection, pieceId, index, pointer, data.length);
    }

    function clear(address collection, uint256 pieceId) external onlyHouse {
        delete _chunks[collection][pieceId];
        emit PieceCleared(collection, pieceId);
    }

    function chunkCount(address collection, uint256 pieceId) external view returns (uint256) {
        return _chunks[collection][pieceId].length;
    }

    function chunk(address collection, uint256 pieceId, uint256 index) external view returns (address) {
        return _chunks[collection][pieceId][index];
    }

    function size(address collection, uint256 pieceId) public view returns (uint256 total) {
        address[] storage list = _chunks[collection][pieceId];
        for (uint256 i; i < list.length; ++i) {
            total += SSTORE2.size(list[i]);
        }
    }

    function read(address collection, uint256 pieceId) external view returns (bytes memory data) {
        address[] storage list = _chunks[collection][pieceId];
        data = new bytes(size(collection, pieceId));
        uint256 offset;
        for (uint256 i; i < list.length; ++i) {
            uint256 dest;
            assembly ("memory-safe") {
                dest := add(add(data, 32), offset)
            }
            offset += SSTORE2.copyTo(list[i], dest);
        }
    }
}
