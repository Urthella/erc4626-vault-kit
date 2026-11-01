// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StrategyVault} from "../src/StrategyVault.sol";
import {TestToken} from "./mocks/Mocks.sol";

/// @notice The classic first-depositor attack: deposit 1 wei, donate a lot so one share is worth a
/// fortune, and let the victim's deposit round down. With 10^6 virtual shares most of the donation
/// belongs to the virtual shares, so the attacker always loses money and the victim loses at most a
/// millionth of the donation. Slippage-protected deposits (ERC-5143) let the victim lose nothing.
contract InflationAttackTest is Test {
    TestToken token;
    StrategyVault vault;
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    function setUp() public {
        token = new TestToken();
        vault = new StrategyVault(IERC20(address(token)), "v", "v", address(this), 0, 0);
    }

    function _attack(uint256 donation) internal returns (uint256 attackerShares) {
        token.mint(attacker, 1 + donation);
        vm.startPrank(attacker);
        token.approve(address(vault), 1);
        attackerShares = vault.deposit(1, attacker);
        token.transfer(address(vault), donation); // inflate the share price
        vm.stopPrank();
    }

    function testFuzz_AttackerLosesAndVictimLosesAtMostDust(uint256 donation, uint256 victimAssets) public {
        donation = bound(donation, 1e18, 1e30);
        victimAssets = bound(victimAssets, 1, 1e30);
        uint256 attackerShares = _attack(donation);

        token.mint(victim, victimAssets);
        vm.startPrank(victim);
        token.approve(address(vault), victimAssets);
        uint256 victimShares = vault.deposit(victimAssets, victim);
        vm.stopPrank();

        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(attackerShares, attacker, attacker);
        vm.prank(victim);
        uint256 victimOut = vault.redeem(victimShares, victim, victim);

        assertLt(attackerOut, 1 + donation, "the attack must not pay");
        // Zeroing out the victim takes a donation of a million times their deposit.
        assertGe(victimOut + donation / 1e6 + 1, victimAssets, "victim lost more than 1e-6 of the donation");
    }

    function test_SlippageBoundMakesTheFrontRunRevert() public {
        uint256 victimAssets = 100e18;
        uint256 expected = vault.previewDeposit(victimAssets); // what the victim's UI quoted
        _attack(1_000_000e18);

        token.mint(victim, victimAssets);
        vm.startPrank(victim);
        token.approve(address(vault), victimAssets);
        uint256 actual = vault.previewDeposit(victimAssets);
        vm.expectRevert(abi.encodeWithSelector(StrategyVault.SlippageExceeded.selector, actual, expected * 99 / 100));
        vault.deposit(victimAssets, victim, expected * 99 / 100);
        vm.stopPrank();
        assertEq(token.balanceOf(victim), victimAssets, "the victim keeps everything");
    }
}
