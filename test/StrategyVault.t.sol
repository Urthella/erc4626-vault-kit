// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {StrategyVault} from "../src/StrategyVault.sol";
import {MockStrategy, TestToken} from "./mocks/Mocks.sol";

contract StrategyVaultTest is Test {
    TestToken token;
    StrategyVault vault;
    MockStrategy strat;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    function setUp() public {
        token = new TestToken();
        vault = new StrategyVault(IERC20(address(token)), "Vault tUSD", "vtUSD", owner, 0, 1_000); // 10% buffer
        strat = new MockStrategy(IERC20(address(token)), address(vault));
        vm.prank(owner);
        vault.setStrategy(strat);
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        token.mint(who, assets);
        vm.startPrank(who);
        token.approve(address(vault), assets);
        shares = vault.deposit(assets, who);
        vm.stopPrank();
    }

    function test_RebalanceKeepsTheBuffer() public {
        _deposit(alice, 100e18);
        vm.prank(owner);
        vault.rebalance();
        assertEq(vault.idle(), 10e18);
        assertEq(strat.totalAssets(), 90e18);
        assertEq(vault.totalAssets(), 100e18);
    }

    function test_WithdrawPullsTheShortfallFromTheStrategy() public {
        _deposit(alice, 100e18);
        vm.prank(owner);
        vault.rebalance();
        vm.prank(alice);
        vault.withdraw(50e18, alice, alice);
        assertEq(token.balanceOf(alice), 50e18);
        assertEq(vault.idle(), 0);
        assertEq(strat.totalAssets(), 50e18);
    }

    function test_YieldGoesToShareholders() public {
        uint256 shares = _deposit(alice, 100e18);
        vm.prank(owner);
        vault.rebalance();
        token.mint(address(strat), 10e18); // the strategy earned 10%
        assertEq(vault.totalAssets(), 110e18);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        // Virtual shares keep a dust-sized slice; alice gets the rest.
        assertApproxEqAbs(out, 110e18, 1e6);
        assertLe(out, 110e18);
    }

    function test_DepositCap() public {
        vm.prank(owner);
        vault.setDepositCap(100e18);
        _deposit(alice, 60e18);
        assertEq(vault.maxDeposit(alice), 40e18);
        token.mint(alice, 41e18);
        vm.startPrank(alice);
        token.approve(address(vault), 41e18);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 41e18, 40e18));
        vault.deposit(41e18, alice);
        vm.stopPrank();
    }

    function test_MaxWithdrawRespectsStrategyLiquidity() public {
        _deposit(alice, 100e18);
        vm.prank(owner);
        vault.rebalance();
        strat.setLiquidityCap(30e18); // 60 of the 90 in the strategy is locked for now
        assertEq(vault.maxWithdraw(alice), 40e18); // 10 idle + 30 liquid
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, 41e18, 40e18));
        vault.withdraw(41e18, alice, alice);
    }

    function test_SetStrategyMigratesEverything() public {
        _deposit(alice, 100e18);
        vm.prank(owner);
        vault.rebalance();
        MockStrategy next = new MockStrategy(IERC20(address(token)), address(vault));
        vm.prank(owner);
        vault.setStrategy(next);
        assertEq(strat.totalAssets(), 0);
        assertEq(vault.idle(), 100e18);
        assertEq(token.allowance(address(vault), address(strat)), 0);
        vm.prank(owner);
        vault.rebalance();
        assertEq(next.totalAssets(), 90e18);
    }

    function test_SetStrategyRefusesAnIlliquidExit() public {
        _deposit(alice, 100e18);
        vm.prank(owner);
        vault.rebalance();
        strat.setLiquidityCap(0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StrategyVault.StrategyIlliquid.selector, 90e18, 0));
        vault.setStrategy(MockStrategy(address(0)));
    }

    function test_StrategyMustUseTheSameAsset() public {
        MockStrategy other = new MockStrategy(IERC20(address(new TestToken())), address(vault));
        vm.prank(owner);
        vm.expectRevert(StrategyVault.StrategyAssetMismatch.selector);
        vault.setStrategy(other);
    }

    function test_AdminFunctionsAreOwnerOnly() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.rebalance();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setDepositCap(1);
        vm.stopPrank();
    }

    function testFuzz_DepositThenRedeemNeverProfits(uint256 assets, uint256 donation) public {
        assets = bound(assets, 1, 1e30);
        donation = bound(donation, 0, 1e30);
        _deposit(makeAddr("first"), 1e18);
        token.mint(address(vault), donation); // someone sends assets straight to the vault
        uint256 shares = _deposit(alice, assets);
        vm.prank(alice);
        assertLe(vault.redeem(shares, alice, alice), assets, "rounding must favor the vault");
    }

    function test_SlippageBoundsOnAllFourEntryPoints() public {
        token.mint(alice, 100e18);
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(50e18, alice, vault.previewDeposit(50e18));
        vm.expectRevert(abi.encodeWithSelector(StrategyVault.SlippageExceeded.selector, shares, shares + 1));
        vault.deposit(50e18, alice, shares + 1);
        uint256 assets = vault.previewMint(shares);
        vm.expectRevert(abi.encodeWithSelector(StrategyVault.SlippageExceeded.selector, assets, assets - 1));
        vault.mint(shares, alice, assets - 1);
        uint256 burned = vault.previewWithdraw(10e18);
        vm.expectRevert(abi.encodeWithSelector(StrategyVault.SlippageExceeded.selector, burned, burned - 1));
        vault.withdraw(10e18, alice, alice, burned - 1);
        uint256 out = vault.previewRedeem(shares);
        vm.expectRevert(abi.encodeWithSelector(StrategyVault.SlippageExceeded.selector, out, out + 1));
        vault.redeem(shares, alice, alice, out + 1);
        assertEq(vault.redeem(shares, alice, alice, out), out);
        vm.stopPrank();
    }
}
