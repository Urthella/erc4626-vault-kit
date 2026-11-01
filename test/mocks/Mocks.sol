// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrategy} from "../../src/IStrategy.sol";

/// @dev Anyone can mint and burn: tests use it to fund users and to fake yield and losses.
contract TestToken is ERC20 {
    constructor() ERC20("Test USD", "tUSD") {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }
}

/// @dev Holds the vault's assets. Yield is minting to it, a loss is burning from it, and
/// setLiquidityCap() makes part of the position temporarily unwithdrawable.
contract MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable vault;
    uint256 public liquidityCap = type(uint256).max;

    constructor(IERC20 token_, address vault_) {
        token = token_;
        vault = vault_;
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function totalAssets() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function available() public view returns (uint256) {
        return Math.min(totalAssets(), liquidityCap);
    }

    function deposit(uint256 assets) external {
        require(msg.sender == vault, "only vault");
        token.safeTransferFrom(vault, address(this), assets);
    }

    function withdraw(uint256 assets) external {
        require(msg.sender == vault, "only vault");
        token.safeTransfer(vault, Math.min(assets, available()));
    }

    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }
}
