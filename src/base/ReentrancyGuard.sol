// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

abstract contract ReentrancyGuard {
    uint256 private _status;

    error Reentrancy();

    modifier nonReentrant() {
        if (_status == 1) revert Reentrancy();
        _status = 1;
        _;
        _status = 0;
    }
}
