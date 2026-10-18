// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBalanceOf, IOwnerOf} from "../interfaces/Interfaces.sol";

/// @notice Holders first: for the first `gateSeconds` of a sale, only holders of an identity.md seat or of at least
/// `gateMinBalance` of a token (IMD) may buy; after that, anyone. The owner sets it before the sale opens: the editions'
/// rules are fixed once their sale opens, THE SOURCE's from its first bid. A seat or token contract that cannot answer
/// counts as not held.
abstract contract HolderGate {
    uint64 public constant MAX_GATE_SECONDS = 30 days;

    address public gateSeats; // identity.md seats (ERC-721)
    address public gateToken; // IMD (ERC-20)
    uint256 public gateMinBalance; // in the token's smallest unit
    uint64 public gateSeconds; // 0: no holders window

    event GateSet(address seats, address token, uint256 minBalance, uint64 gateSeconds);

    error NotEligible();
    error BadGate();

    function _setGate(address seats, address token, uint256 minBalance, uint64 seconds_) internal {
        if (seconds_ > MAX_GATE_SECONDS) revert BadGate();
        bool tokenGate = token != address(0) && minBalance > 0;
        if (seconds_ > 0 && seats == address(0) && !tokenGate) revert BadGate(); // a window nobody could enter
        if ((token == address(0)) != (minBalance == 0)) revert BadGate(); // a token needs a minimum, and back
        gateSeats = seats;
        gateToken = token;
        gateMinBalance = minBalance;
        gateSeconds = seconds_;
        emit GateSet(seats, token, minBalance, seconds_);
    }

    /// @dev Whether a sale that started at `start` is still in its holders window.
    function _inGate(uint256 start) internal view returns (bool) {
        return gateSeconds != 0 && start != 0 && block.timestamp < start + gateSeconds;
    }

    /// @notice Holds at least the minimum of the gate token.
    function holdsToken(address account) public view returns (bool) {
        address t = gateToken;
        if (t == address(0)) return false;
        try IBalanceOf(t).balanceOf(account) returns (uint256 b) {
            return b >= gateMinBalance;
        } catch {
            return false;
        }
    }

    /// @notice Holds at least one identity.md seat.
    function holdsSeat(address account) public view returns (bool) {
        address s = gateSeats;
        if (s == address(0)) return false;
        try IBalanceOf(s).balanceOf(account) returns (uint256 b) {
            return b > 0;
        } catch {
            return false;
        }
    }

    /// @dev Holds this particular seat.
    function _ownsSeat(address account, uint256 seatId) internal view returns (bool) {
        address s = gateSeats;
        if (s == address(0)) return false;
        try IOwnerOf(s).ownerOf(seatId) returns (address o) {
            return o == account;
        } catch {
            return false;
        }
    }
}
