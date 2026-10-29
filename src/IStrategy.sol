// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Somewhere a StrategyVault parks idle assets to earn yield. The vault is its only depositor.
interface IStrategy {
    /// @notice The ERC-20 the strategy takes; must be the vault's asset.
    function asset() external view returns (address);

    /// @notice Assets held for the vault, including accrued yield and net of losses.
    function totalAssets() external view returns (uint256);

    /// @notice Assets that could be sent back to the vault right now. Never more than totalAssets.
    function available() external view returns (uint256);

    /// @notice Pulls `assets` from the vault, which has approved them, and puts them to work.
    function deposit(uint256 assets) external;

    /// @notice Sends up to `assets` back to the vault. May send less when the position is illiquid.
    function withdraw(uint256 assets) external;
}
