// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Stand-in for the identity.md seat collection (ERC-721): anyone can mint a seat id to anyone, for tests and
/// test networks only.
contract MockSeats {
    mapping(uint256 => address) public ownerOfSeat;

    function mint(address to, uint256 seatId) external {
        require(ownerOfSeat[seatId] == address(0), "minted");
        ownerOfSeat[seatId] = to;
    }

    function transferFrom(address from, address to, uint256 seatId) external {
        require(ownerOfSeat[seatId] == from && msg.sender == from, "not owner");
        ownerOfSeat[seatId] = to;
    }

    function ownerOf(uint256 seatId) external view returns (address o) {
        o = ownerOfSeat[seatId];
        require(o != address(0), "no seat");
    }
}
