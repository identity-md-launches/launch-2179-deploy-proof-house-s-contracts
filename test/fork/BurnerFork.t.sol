// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ImdBuybackBurner} from "../../src/ImdBuybackBurner.sol";

contract OwnedStub {
    address public owner;

    constructor(address o) {
        owner = o;
    }
}

/// @dev The burner against the real ETH/IMD Uniswap v4 pool on an Ethereum mainnet fork. Runs only with FORK_URL set:
///   FORK_URL=<mainnet rpc> forge test --match-path test/fork/BurnerFork.t.sol -vv
contract BurnerForkTest is Test {
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // the deepest ETH/IMD pool: 1% fee, tick spacing 200, no hook (pool id 0xb07d640f…abfb3)
    uint24 internal constant FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;

    ImdBuybackBurner internal burner;
    address internal curator = makeAddr("curator");

    function setUp() public {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        burner = new ImdBuybackBurner(address(new OwnedStub(curator)), POOL_MANAGER, IMD, FEE, TICK_SPACING, address(0));
        vm.deal(address(burner), 1 ether);
    }

    function _dead() internal view returns (uint256) {
        (bool ok, bytes memory ret) = IMD.staticcall(abi.encodeWithSignature("balanceOf(address)", DEAD));
        require(ok);
        return abi.decode(ret, (uint256));
    }

    function test_fork_ethBecomesBurnedImd() public {
        uint256 before = _dead();
        vm.prank(curator);
        uint256 out = burner.burnEth(0.1 ether, 1, block.timestamp);
        assertGt(out, 0);
        assertEq(_dead() - before, out, "every IMD bought went to the dead address");
        assertEq(address(burner).balance, 0.9 ether);
        console2.log("0.1 ETH bought and burned this many IMD (wei):", out);
    }

    function test_fork_minimumIsEnforced() public {
        vm.prank(curator);
        vm.expectRevert();
        burner.burnEth(0.1 ether, type(uint128).max, block.timestamp);
        assertEq(address(burner).balance, 1 ether, "a refused swap spends nothing");
    }

    function test_fork_aBurnerFixedToAPoolThatDoesNotExistRefuses() public {
        ImdBuybackBurner wrong = new ImdBuybackBurner(address(new OwnedStub(curator)), POOL_MANAGER, IMD, 3000, 60, address(0));
        vm.deal(address(wrong), 1 ether);
        vm.prank(curator);
        vm.expectRevert();
        wrong.burnEth(0.1 ether, 1, block.timestamp);
    }
}
