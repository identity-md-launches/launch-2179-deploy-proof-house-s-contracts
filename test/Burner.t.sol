// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ImdBuybackBurner} from "../src/ImdBuybackBurner.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @dev The IMD buyback and burn: the ledger releases the buyback balance to it; the curator swaps ETH for IMD on the
/// one pool fixed at deployment, with a minimum above zero and a deadline, straight to the dead address; anyone burns
/// IMD it holds; nothing goes anywhere else.
contract BurnerTest is Fixture {
    MockPoolManager internal pm;
    ImdBuybackBurner internal burner;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant ETH = address(0);
    uint256 internal constant RATE = 50_000; // IMD wei per ETH wei in the stand-in pool

    function setUp() public override {
        super.setUp();
        pm = new MockPoolManager(RATE);
        imd.mint(address(pm), 1_000_000 ether);
        burner = new ImdBuybackBurner(address(house), address(pm), address(imd), 10_000, 200, address(0));
        vm.prank(curator);
        house.setBuybackBurner(address(burner));
    }

    function _sell(uint256 price) internal {
        _publishAll();
        _openSale(price);
        _buyAndAssign(alice, address(0), 1); // no broker: 5% + the unearned 15% go to the buyback
    }

    function test_editionSaleToBurnedImd() public {
        _sell(1 ether);
        assertEq(house.balances(house.BUYBACK(), ETH), 0.2 ether, "20% with no agent");
        house.releaseBuyback(ETH); // anyone
        assertEq(address(burner).balance, 0.2 ether);
        vm.prank(curator);
        uint256 out = burner.burnEth(0.2 ether, 0.2 ether * RATE, block.timestamp);
        assertEq(out, 0.2 ether * RATE);
        assertEq(imd.balanceOf(DEAD), out, "the IMD went straight to the dead address");
        assertEq(address(burner).balance, 0);
        assertEq(imd.balanceOf(address(burner)), 0, "nothing stays behind");
        assertEq(burner.totalEthSwapped(), 0.2 ether);
        assertEq(burner.totalImdBurned(), out);
        (address c0, address c1, uint24 fee, int24 ts, address hooks) = pm.lastKey();
        assertEq(c0, address(0));
        assertEq(c1, address(imd));
        assertEq(fee, 10_000);
        assertEq(ts, 200);
        assertEq(hooks, address(0));
        assertEq(burner.poolFee(), 10_000);
        assertEq(burner.poolTickSpacing(), 200);
        assertEq(burner.poolHooks(), address(0));
    }

    function test_onlyTheCuratorSwaps_withAMinimumAndADeadline() public {
        vm.deal(address(burner), 1 ether);
        vm.prank(alice);
        vm.expectRevert(ImdBuybackBurner.NotCurator.selector);
        burner.burnEth(1 ether, 1, block.timestamp);
        vm.startPrank(curator);
        vm.expectRevert(ImdBuybackBurner.NoMinimum.selector);
        burner.burnEth(1 ether, 0, block.timestamp); // a swap always names a minimum
        vm.expectRevert(abi.encodeWithSelector(ImdBuybackBurner.TooLittleOut.selector, 1 ether * RATE, 1 ether * RATE + 1));
        burner.burnEth(1 ether, 1 ether * RATE + 1, block.timestamp);
        vm.expectRevert(ImdBuybackBurner.Expired.selector);
        burner.burnEth(1 ether, 1, block.timestamp - 1);
        vm.expectRevert(ImdBuybackBurner.BadAmount.selector);
        burner.burnEth(2 ether, 1, block.timestamp); // more than it holds
        vm.expectRevert(ImdBuybackBurner.BadAmount.selector);
        burner.burnEth(0, 1, block.timestamp);
        // in parts, to keep each swap small
        burner.burnEth(0.4 ether, 0.4 ether * RATE, block.timestamp);
        burner.burnEth(0.6 ether, 0.6 ether * RATE, block.timestamp);
        vm.stopPrank();
        assertEq(address(burner).balance, 0);
        assertEq(imd.balanceOf(DEAD), 1 ether * RATE);
    }

    function test_theNewOwnerSwapsAfterAHandover() public {
        vm.deal(address(burner), 1 ether);
        vm.prank(curator);
        house.transferOwnership(bob);
        vm.prank(bob);
        house.acceptOwnership();
        vm.prank(curator);
        vm.expectRevert(ImdBuybackBurner.NotCurator.selector);
        burner.burnEth(1 ether, 1, block.timestamp);
        vm.prank(bob);
        burner.burnEth(1 ether, 1, block.timestamp);
    }

    /// @dev After 60 days without a curator swap anyone may swap, in small steps, so the ETH here is never stuck.
    function test_anyoneSwapsInSmallStepsAfter60QuietDays() public {
        vm.deal(address(burner), 1 ether);
        vm.prank(alice);
        vm.expectRevert(ImdBuybackBurner.NotCurator.selector);
        burner.burnEth(0.05 ether, 1, block.timestamp);
        vm.warp(block.timestamp + burner.IDLE());
        vm.prank(alice);
        vm.expectRevert(ImdBuybackBurner.BadAmount.selector);
        burner.burnEth(0.05 ether + 1, 1, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(ImdBuybackBurner.NoMinimum.selector);
        burner.burnEth(0.05 ether, 0, block.timestamp);
        vm.prank(alice);
        burner.burnEth(0.05 ether, 0.05 ether * RATE, block.timestamp);
        assertEq(imd.balanceOf(DEAD), 0.05 ether * RATE, "straight to the dead address");
        vm.prank(bob);
        vm.expectRevert(ImdBuybackBurner.TooSoon.selector);
        burner.burnEth(0.05 ether, 1, block.timestamp);
        vm.warp(block.timestamp + burner.PUBLIC_GAP());
        // the day's one public swap is always the full step: nobody can spend it on dust
        vm.prank(bob);
        vm.expectRevert(ImdBuybackBurner.BadAmount.selector);
        burner.burnEth(1 gwei, 1, block.timestamp);
        vm.prank(bob);
        burner.burnEth(0.05 ether, 1, block.timestamp);
        // the last of it, when less than a step is left
        vm.deal(address(burner), 0.03 ether);
        vm.warp(block.timestamp + burner.PUBLIC_GAP());
        vm.prank(bob);
        vm.expectRevert(ImdBuybackBurner.BadAmount.selector);
        burner.burnEth(0.02 ether, 1, block.timestamp);
        vm.prank(bob);
        burner.burnEth(0.03 ether, 1, block.timestamp);
        vm.deal(address(burner), 1 ether);
        // the curator swaps again: the quiet period starts over
        vm.prank(curator);
        burner.burnEth(0.1 ether, 1, block.timestamp);
        vm.warp(block.timestamp + burner.PUBLIC_GAP());
        vm.prank(alice);
        vm.expectRevert(ImdBuybackBurner.NotCurator.selector);
        burner.burnEth(0.01 ether, 1, block.timestamp);
    }

    function test_anyoneBurnsHeldImd() public {
        imd.mint(address(burner), 7 ether);
        vm.prank(carol);
        assertEq(burner.burnImd(), 7 ether);
        assertEq(imd.balanceOf(DEAD), 7 ether);
        vm.expectRevert(ImdBuybackBurner.NothingToBurn.selector);
        burner.burnImd();
    }

    function test_onlyThePoolManagerCallsBack() public {
        vm.expectRevert(ImdBuybackBurner.NotPoolManager.selector);
        burner.unlockCallback("");
    }

    function test_constructorChecks() public {
        vm.expectRevert(ImdBuybackBurner.ZeroAddress.selector);
        new ImdBuybackBurner(address(0), address(pm), address(imd), 10_000, 200, address(0));
        vm.expectRevert(ImdBuybackBurner.ZeroAddress.selector);
        new ImdBuybackBurner(address(house), address(pm), address(0), 10_000, 200, address(0));
    }
}
