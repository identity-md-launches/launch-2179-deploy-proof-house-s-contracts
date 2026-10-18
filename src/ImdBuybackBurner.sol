// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The parts of Uniswap v4 this contract uses (v4-core IPoolManager, PoolKey, SwapParams, IUnlockCallback).
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IOwnedHouse {
    function owner() external view returns (address);
}

interface IERC20Burnable {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Proof House's IMD buyback and burn. ArtHouse sends it the buyback balance (5% of every edition sale, plus
/// any agent share nobody earned) with releaseBuyback. ETH is swapped for IMD on an ETH/IMD Uniswap v4 pool and the
/// IMD goes straight to the dead address; IMD paid in directly goes there too. IMD has no burn function, so the dead
/// address is the burn.
/// Nothing here can send ETH or IMD anywhere else. Anyone can burn IMD the contract holds. Swapping ETH is the
/// curator's (ArtHouse's owner; after 60 days without a curator swap, anyone's, in small steps), always on the one ETH/IMD pool fixed at deployment (its fee, tick spacing and hook
/// can never change, so the ETH can't be routed through a pool someone controls), with a minimum IMD out above zero
/// and a deadline. The curator picks the amount and the minimum. A public swap's minimum is the caller's own, so a
/// caller could sandwich it: each is capped at PUBLIC_MAX and one a day, which bounds that loss.
contract ImdBuybackBurner is IUnlockCallback {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128739 + 1; // TickMath.MIN_SQRT_PRICE + 1: no price limit

    IOwnedHouse public immutable house;
    IPoolManager public immutable poolManager;
    address public immutable imd;
    // the ETH/IMD pool, fixed forever: currency0 ETH (address 0), currency1 IMD
    uint24 public immutable poolFee;
    int24 public immutable poolTickSpacing;
    address public immutable poolHooks;

    /// @notice If the curator hasn't swapped for IDLE, anyone may: exactly PUBLIC_MAX (or all that is left, if less)
    /// and one swap per PUBLIC_GAP, so the ETH here can never be stuck and nobody can spend the day's swap on dust.
    uint256 public constant IDLE = 60 days;
    uint256 public constant PUBLIC_MAX = 0.05 ether;
    uint256 public constant PUBLIC_GAP = 1 days;

    uint256 public totalEthSwapped;
    uint256 public totalImdBurned;
    uint64 public lastCuratorSwapAt; // starts at deployment
    uint64 public lastPublicSwapAt;

    event Burned(uint256 ethIn, uint256 imdOut, uint24 fee, int24 tickSpacing, address hooks);
    event ImdBurned(uint256 amount);

    error ZeroAddress();
    error NotCurator();
    error NotPoolManager();
    error Expired();
    error BadAmount();
    error TooLittleOut(uint256 out, uint256 minOut);
    error NothingToBurn();
    error NoMinimum();
    error TooSoon();
    error TransferFailed();

    constructor(address house_, address poolManager_, address imd_, uint24 poolFee_, int24 poolTickSpacing_, address poolHooks_) {
        if (house_ == address(0) || poolManager_ == address(0) || imd_ == address(0)) revert ZeroAddress();
        house = IOwnedHouse(house_);
        poolManager = IPoolManager(poolManager_);
        imd = imd_;
        poolFee = poolFee_;
        poolTickSpacing = poolTickSpacing_;
        poolHooks = poolHooks_;
        lastCuratorSwapAt = uint64(block.timestamp);
    }

    receive() external payable {}

    /// @notice Swap `amountIn` of the ETH held here for IMD on the fixed ETH/IMD pool and send the IMD to the dead
    /// address. Reverts unless at least `minImdOut` (above zero) is burned and before `deadline`. The curator's; anyone
    /// else's only after IDLE without a curator swap, within PUBLIC_MAX and PUBLIC_GAP.
    function burnEth(uint256 amountIn, uint256 minImdOut, uint256 deadline) external returns (uint256 imdOut) {
        if (msg.sender == house.owner()) {
            lastCuratorSwapAt = uint64(block.timestamp);
        } else {
            if (block.timestamp < uint256(lastCuratorSwapAt) + IDLE) revert NotCurator();
            uint256 bal = address(this).balance;
            if (amountIn != (bal < PUBLIC_MAX ? bal : PUBLIC_MAX)) revert BadAmount();
            if (lastPublicSwapAt != 0 && block.timestamp < uint256(lastPublicSwapAt) + PUBLIC_GAP) revert TooSoon();
            lastPublicSwapAt = uint64(block.timestamp);
        }
        if (block.timestamp > deadline) revert Expired();
        if (minImdOut == 0) revert NoMinimum();
        if (amountIn == 0 || amountIn > address(this).balance || amountIn > uint256(type(int256).max)) revert BadAmount();
        PoolKey memory key = PoolKey(address(0), imd, poolFee, poolTickSpacing, poolHooks);
        bytes memory ret = poolManager.unlock(abi.encode(key, amountIn));
        uint256 ethIn;
        (ethIn, imdOut) = abi.decode(ret, (uint256, uint256));
        if (imdOut < minImdOut) revert TooLittleOut(imdOut, minImdOut);
        totalEthSwapped += ethIn;
        totalImdBurned += imdOut;
        emit Burned(ethIn, imdOut, poolFee, poolTickSpacing, poolHooks);
    }

    /// @notice Anyone may send the IMD held here (paid in IMD, or sent by anyone) to the dead address.
    function burnImd() external returns (uint256 amount) {
        amount = IERC20Burnable(imd).balanceOf(address(this));
        if (amount == 0) revert NothingToBurn();
        if (!IERC20Burnable(imd).transfer(DEAD, amount)) revert TransferFailed();
        totalImdBurned += amount;
        emit ImdBurned(amount);
    }

    /// @dev The pool manager calls back here inside burnEth's unlock: an exact-input swap of ETH for IMD, paid in
    /// ETH, with the IMD taken straight to the dead address.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint256 amountIn) = abi.decode(data, (PoolKey, uint256));
        int256 delta = poolManager.swap(
            key, SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_SQRT_PRICE_LIMIT}), ""
        );
        int128 amount0 = int128(delta >> 128); // ETH: what this contract owes, negative
        int128 amount1 = int128(delta); // IMD: what the pool owes this contract, positive
        if (amount0 > 0 || amount1 < 0) revert BadAmount();
        uint256 ethIn = uint256(uint128(-amount0));
        uint256 imdOut = uint256(uint128(amount1));
        poolManager.settle{value: ethIn}();
        poolManager.take(imd, DEAD, imdOut);
        return abi.encode(ethIn, imdOut);
    }
}
