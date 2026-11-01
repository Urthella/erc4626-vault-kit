// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrategy} from "./IStrategy.sol";

/// @title StrategyVault
/// @notice An ERC-4626 vault that keeps a buffer of idle assets for cheap withdrawals and puts the
/// rest into a pluggable strategy. Built on OpenZeppelin's ERC4626. Unaudited: testnets and learning only.
contract StrategyVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_BPS = 10_000;

    IStrategy public strategy;
    /// @notice Upper bound on totalAssets accepted through deposits; 0 means no cap.
    uint256 public depositCap;
    /// @notice Share of totalAssets that rebalance() leaves idle, in basis points.
    uint16 public bufferBps;

    event StrategyChanged(address indexed previous, address indexed next);
    event Rebalanced(uint256 idle, uint256 inStrategy);
    event DepositCapChanged(uint256 cap);
    event BufferChanged(uint16 bps);

    error StrategyAssetMismatch();
    error StrategyIlliquid(uint256 needed, uint256 received);
    error InvalidBps();
    error SlippageExceeded(uint256 actual, uint256 limit);

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner_,
        uint256 cap_,
        uint16 bufferBps_
    ) ERC20(name_, symbol_) ERC4626(asset_) Ownable(owner_) {
        if (bufferBps_ > MAX_BPS) revert InvalidBps();
        depositCap = cap_;
        bufferBps = bufferBps_;
    }

    /// @dev 10^6 virtual shares per virtual asset: a first-depositor "inflation" attack has to donate
    /// a million times what it could steal. See test/InflationAttack.t.sol.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function idle() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function totalAssets() public view override returns (uint256) {
        IStrategy s = strategy;
        return idle() + (address(s) == address(0) ? 0 : s.totalAssets());
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (depositCap == 0) return super.maxDeposit(receiver);
        uint256 total = totalAssets();
        return total >= depositCap ? 0 : depositCap - total;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        if (depositCap == 0) return super.maxMint(receiver);
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    /// @dev ERC-4626 requires max* to never promise more than a call would actually deliver,
    /// so both are capped by what is withdrawable right now.
    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), _liquidAssets());
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(super.maxRedeem(owner), _convertToShares(_liquidAssets(), Math.Rounding.Floor));
    }

    function _liquidAssets() internal view returns (uint256) {
        IStrategy s = strategy;
        return idle() + (address(s) == address(0) ? 0 : s.available());
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        uint256 cash = idle();
        if (cash < assets) _pull(strategy, assets - cash);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Trusts the balance change, not the strategy's word, for what came back.
    function _pull(IStrategy s, uint256 needed) internal {
        uint256 before = idle();
        s.withdraw(needed);
        uint256 received = idle() - before;
        if (received < needed) revert StrategyIlliquid(needed, received);
    }

    /// @notice Moves assets so bufferBps of totalAssets sits idle and the rest is in the strategy.
    function rebalance() external onlyOwner {
        IStrategy s = strategy;
        if (address(s) == address(0)) return;
        uint256 target = Math.mulDiv(totalAssets(), bufferBps, MAX_BPS);
        uint256 cash = idle();
        if (cash > target) {
            IERC20(asset()).forceApprove(address(s), cash - target);
            s.deposit(cash - target);
        } else if (cash < target) {
            s.withdraw(Math.min(target - cash, s.available())); // best effort when the strategy is illiquid
        }
        emit Rebalanced(idle(), s.totalAssets());
    }

    /// @notice Empties the current strategy (it must be fully liquid) and switches to `next`.
    function setStrategy(IStrategy next) external onlyOwner {
        if (address(next) != address(0) && next.asset() != asset()) revert StrategyAssetMismatch();
        IStrategy previous = strategy;
        if (address(previous) != address(0)) {
            uint256 held = previous.totalAssets();
            if (held > 0) _pull(previous, held);
            IERC20(asset()).forceApprove(address(previous), 0);
        }
        strategy = next;
        emit StrategyChanged(address(previous), address(next));
    }

    // ERC-5143 slippage protection: the plain ERC-4626 functions plus a bound the caller computed
    // beforehand. A front-run that moves the share price (like an inflation attack) reverts instead.

    function deposit(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares) {
        shares = deposit(assets, receiver);
        if (shares < minShares) revert SlippageExceeded(shares, minShares);
    }

    function mint(uint256 shares, address receiver, uint256 maxAssets) external returns (uint256 assets) {
        assets = mint(shares, receiver);
        if (assets > maxAssets) revert SlippageExceeded(assets, maxAssets);
    }

    function withdraw(uint256 assets, address receiver, address owner, uint256 maxShares)
        external
        returns (uint256 shares)
    {
        shares = withdraw(assets, receiver, owner);
        if (shares > maxShares) revert SlippageExceeded(shares, maxShares);
    }

    function redeem(uint256 shares, address receiver, address owner, uint256 minAssets)
        external
        returns (uint256 assets)
    {
        assets = redeem(shares, receiver, owner);
        if (assets < minAssets) revert SlippageExceeded(assets, minAssets);
    }

    function setDepositCap(uint256 cap) external onlyOwner {
        depositCap = cap;
        emit DepositCapChanged(cap);
    }

    function setBufferBps(uint16 bps) external onlyOwner {
        if (bps > MAX_BPS) revert InvalidBps();
        bufferBps = bps;
        emit BufferChanged(bps);
    }
}
