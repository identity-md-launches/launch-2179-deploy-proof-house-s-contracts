// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey, SwapParams, IUnlockCallback} from "../../src/ImdBuybackBurner.sol";

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Stand-in for Uniswap v4's PoolManager, for tests only: one fixed price (`imdPerEth` IMD wei per ETH wei),
/// exact-input ETH to IMD swaps, and the same flash accounting rule: whatever is owed inside unlock must be settled
/// before it ends. Holds IMD to pay out.
contract MockPoolManager {
    uint256 public imdPerEth;
    bool public unlocked;
    int256 internal owedEth; // ETH the locker still has to pay in
    int256 internal owedImd; // IMD the pool still has to pay out
    PoolKey public lastKey;

    error ManagerLocked();
    error CurrencyNotSettled();

    constructor(uint256 imdPerEth_) {
        imdPerEth = imdPerEth_;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        if (owedEth != 0 || owedImd != 0) revert CurrencyNotSettled();
        unlocked = false;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (int256) {
        if (!unlocked) revert ManagerLocked();
        require(key.currency0 == address(0) && params.zeroForOne && params.amountSpecified < 0, "mock: ETH in only");
        lastKey = key;
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 out = amountIn * imdPerEth;
        owedEth += int256(amountIn);
        owedImd += int256(out);
        // BalanceDelta: amount0 in the upper 128 bits, amount1 in the lower 128
        return (int256(-int128(int256(amountIn))) << 128) | int256(uint256(uint128(int128(int256(out)))));
    }

    function settle() external payable returns (uint256) {
        if (!unlocked) revert ManagerLocked();
        owedEth -= int256(msg.value);
        return msg.value;
    }

    function take(address currency, address to, uint256 amount) external {
        if (!unlocked) revert ManagerLocked();
        owedImd -= int256(amount);
        require(IERC20Min(currency).transfer(to, amount), "mock: transfer");
    }
}
