// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StrategyVault} from "../src/StrategyVault.sol";
import {MockStrategy, TestToken} from "./mocks/Mocks.sol";

/// @dev The fuzzer calls these in random order with random arguments. Every action is bounded to
/// something a real user or market could do, so any revert is a bug (fail_on_revert = true).
contract Handler is Test {
    StrategyVault public vault;
    TestToken public token;
    MockStrategy public strat;
    address[] public actors;

    constructor(StrategyVault vault_, TestToken token_, MockStrategy strat_) {
        vault = vault_;
        token = token_;
        strat = strat_;
        for (uint256 i = 0; i < 4; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", vm.toString(i)))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function deposit(uint256 seed, uint256 assets) external {
        address a = actors[seed % actors.length];
        assets = bound(assets, 0, 1e30);
        token.mint(a, assets);
        vm.startPrank(a);
        token.approve(address(vault), assets);
        vault.deposit(assets, a);
        vm.stopPrank();
    }

    function redeem(uint256 seed, uint256 shares) external {
        address a = actors[seed % actors.length];
        shares = bound(shares, 0, vault.maxRedeem(a));
        vm.prank(a);
        vault.redeem(shares, a, a);
    }

    function withdraw(uint256 seed, uint256 assets) external {
        address a = actors[seed % actors.length];
        assets = bound(assets, 0, vault.maxWithdraw(a));
        vm.prank(a);
        vault.withdraw(assets, a, a);
    }

    function rebalance() external {
        vm.prank(vault.owner());
        vault.rebalance();
    }

    function earn(uint256 amount) external {
        token.mint(address(strat), bound(amount, 0, 1e27));
    }

    function lose(uint256 amount) external {
        token.burn(address(strat), bound(amount, 0, strat.totalAssets() / 10));
    }
}

contract InvariantsTest is Test {
    StrategyVault vault;
    TestToken token;
    MockStrategy strat;
    Handler handler;

    function setUp() public {
        token = new TestToken();
        vault = new StrategyVault(IERC20(address(token)), "v", "v", address(this), 0, 1_500);
        strat = new MockStrategy(IERC20(address(token)), address(vault));
        vault.setStrategy(strat);
        handler = new Handler(vault, token, strat);
        targetContract(address(handler));
    }

    function invariant_totalAssetsIsIdlePlusStrategy() public view {
        assertEq(vault.totalAssets(), token.balanceOf(address(vault)) + token.balanceOf(address(strat)));
    }

    function invariant_solvent() public view {
        assertLe(
            vault.convertToAssets(vault.totalSupply()), vault.totalAssets(), "shares claim more than the vault holds"
        );
    }

    function invariant_sharesAddUp() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += vault.balanceOf(handler.actors(i));
        }
        assertEq(sum, vault.totalSupply());
    }

    function invariant_everyoneCanExitTogether() public view {
        uint256 claims;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            claims += vault.maxWithdraw(handler.actors(i));
        }
        assertLe(claims, vault.totalAssets());
    }
}
