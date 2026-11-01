// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626Test} from "erc4626-tests/ERC4626.test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StrategyVault} from "../src/StrategyVault.sol";
import {MockStrategy, TestToken} from "./mocks/Mocks.sol";

/// @notice a16z's ERC-4626 property suite, run against the vault with a strategy attached and most
/// assets moved into it, so every withdrawal path is exercised with exact rounding (delta 0).
contract StrategyVaultConformanceTest is ERC4626Test {
    StrategyVault vault;

    function setUp() public override {
        TestToken token = new TestToken();
        vault = new StrategyVault(IERC20(address(token)), "Vault tUSD", "vtUSD", address(this), 0, 2_000);
        vault.setStrategy(new MockStrategy(IERC20(address(token)), address(vault)));
        _underlying_ = address(token);
        _vault_ = address(vault);
        _delta_ = 0;
        _vaultMayBeEmpty = false;
        _unlimitedAmount = false;
    }

    function setUpVault(Init memory init) public override {
        super.setUpVault(init);
        vault.rebalance(); // 80% into the strategy
    }
}
