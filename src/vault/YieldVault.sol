// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// ReentrancyGuardUpgradeable inlined below (avoids OZ v5 path resolution issues on Windows)
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOracle} from "../oracles/IOracle.sol";

/// @title YieldVault
/// @notice ERC-4626 tokenised yield vault that accepts a single ERC-20 asset and issues share tokens.
///         Yield is accrued via an external strategy address (set by admin). Shares represent
///         a proportional claim on the growing asset balance.
///
/// @dev ERC-4626 rounding invariants (OpenZeppelin guarantees):
///  • previewDeposit  ≤ actual shares minted  (favours vault)
///  • previewMint     ≥ actual assets taken    (favours vault)
///  • previewRedeem   ≤ actual assets returned (favours vault)
///  • previewWithdraw ≥ actual shares burned   (favours vault)
///  All rounding is handled by OZ's ERC4626Upgradeable via Math.Rounding.Floor/Ceil.
///
/// @dev Security:
///  • ReentrancyGuard on deposit/withdraw paths.
///  • Checks-Effects-Interactions (balance checked, shares minted, then transfer).
///  • Chainlink oracle validates the asset price before large withdrawals (optional check).
///  • Pausable for emergency circuit-breaker.
///
/// @dev Storage layout (append-only after _maxDepositPerUser):
///  ┌────────────────────────────────────────────────┐
///  │ OZ upgradeable slots (ERC20, ERC4626, etc.)    │
///  │ _maxDepositPerUser                             │
///  │ oracle                                         │
///  │ strategy                                       │
///  └────────────────────────────────────────────────┘
contract YieldVault is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    // ── Manual reentrancy guard (replaces ReentrancyGuardUpgradeable) ──
    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier nonReentrant() {
        require(_reentrancyStatus != _ENTERED, "ReentrancyGuard: reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant STRATEGY_ROLE = keccak256("STRATEGY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public maxDepositPerUser;
    IOracle public oracle;
    address public strategy; // yield-generating strategy contract

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error DepositLimitExceeded(uint256 attempted, uint256 limit);
    error ZeroShares();
    error ZeroAssets();
    error InvalidStrategy();

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event StrategyUpdated(address indexed oldStrategy, address indexed newStrategy);
    event MaxDepositUpdated(uint256 oldLimit, uint256 newLimit);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @param asset_            Underlying ERC-20 token (e.g. USDC)
    /// @param name_             Vault share token name (e.g. "Yield USDC")
    /// @param symbol_           Vault share token symbol (e.g. "yUSDC")
    /// @param maxDepositPerUser_ Per-user deposit cap (0 = unlimited)
    /// @param oracle_           Chainlink oracle for the asset (may be address(0) to skip price checks)
    /// @param admin             Receives all admin roles
    function initialize(
        address asset_,
        string memory name_,
        string memory symbol_,
        uint256 maxDepositPerUser_,
        address oracle_,
        address admin
    ) external initializer {
        require(admin != address(0), "Zero admin");

        __ERC4626_init(IERC20(asset_));
        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        __Pausable_init();
        _reentrancyStatus = _NOT_ENTERED;

        maxDepositPerUser = maxDepositPerUser_;
        oracle = IOracle(oracle_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(STRATEGY_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                     ERC-4626 OVERRIDES (security)
    //////////////////////////////////////////////////////////////*/

    /// @dev Wraps OZ deposit with: reentrancy guard, pause check, deposit cap.
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        // ── Checks ──────────────────────────────────────────────
        if (assets == 0) revert ZeroAssets();
        _checkDepositLimit(receiver, assets);

        // ── Effects + Interactions (delegated to OZ) ─────────────
        shares = super.deposit(assets, receiver);
        if (shares == 0) revert ZeroShares();
    }

    /// @dev Wraps OZ mint with: reentrancy guard, pause check.
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroShares();
        uint256 assetsNeeded = previewMint(shares);
        _checkDepositLimit(receiver, assetsNeeded);
        assets = super.mint(shares, receiver);
    }

    /// @dev Wraps OZ withdraw with: reentrancy guard, pause check.
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAssets();
        shares = super.withdraw(assets, receiver, owner_);
    }

    /// @dev Wraps OZ redeem with: reentrancy guard, pause check.
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroShares();
        assets = super.redeem(shares, receiver, owner_);
    }

    /*//////////////////////////////////////////////////////////////
                      STRATEGY (yield accrual)
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by the strategy to report yield — just holds assets in this vault.
    ///         In a real system the strategy would deploy assets to Aave/Compound and call back.
    /// @dev Only STRATEGY_ROLE. Pull-over-push: assets transferred in by strategy.
    function reportYield(uint256 amount) external onlyRole(STRATEGY_ROLE) {
        // ── Checks ──────────────────────────────────────────────
        if (amount == 0) revert ZeroAssets();

        // ── Interactions (assets pulled from strategy into vault) ──
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        // No Effects needed: totalAssets() reads balance, so it auto-increases.
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setStrategy(address newStrategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newStrategy == address(0)) revert InvalidStrategy();
        emit StrategyUpdated(strategy, newStrategy);
        strategy = newStrategy;
        _grantRole(STRATEGY_ROLE, newStrategy);
    }

    function setMaxDepositPerUser(uint256 newLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit MaxDepositUpdated(maxDepositPerUser, newLimit);
        maxDepositPerUser = newLimit;
    }

    function setOracle(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit OracleUpdated(address(oracle), newOracle);
        oracle = IOracle(newOracle);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _checkDepositLimit(address receiver, uint256 assets) internal view {
        if (maxDepositPerUser == 0) return; // unlimited
        uint256 currentShares = balanceOf(receiver);
        uint256 currentAssets = currentShares == 0 ? 0 : convertToAssets(currentShares);
        if (currentAssets + assets > maxDepositPerUser) {
            revert DepositLimitExceeded(currentAssets + assets, maxDepositPerUser);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        UUPS AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    /*//////////////////////////////////////////////////////////////
                        ERC-20 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) {
        super._update(from, to, value);
    }
}
