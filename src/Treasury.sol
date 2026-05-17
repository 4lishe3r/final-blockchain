// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Treasury
/// @notice Protocol treasury that accumulates fees. All withdrawals must go through governance
///         (i.e., the Timelock). Implements Pull-over-push payments.
///
/// @dev Design patterns:
///  • Pull-over-push: recipients call claim(), Treasury never pushes ETH/tokens automatically.
///  • Access Control: only SPENDER_ROLE (held by Timelock) can allocate grants.
///  • Checks-Effects-Interactions: state updated before any transfer.
///  • ReentrancyGuard: protects claimETH and claimToken.
///  • No use of transfer/send for ETH — uses call{value:} with success check.
contract Treasury is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Held by the TimelockController. The only role that can allocate grants.
    bytes32 public constant SPENDER_ROLE = keccak256("SPENDER_ROLE");

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pending ETH grants allocated to recipients. Pull-over-push.
    mapping(address => uint256) public pendingETH;

    /// @notice Pending ERC-20 grants: recipient → token → amount.
    mapping(address => mapping(address => uint256)) public pendingTokens;

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientBalance(uint256 requested, uint256 available);
    error ETHTransferFailed();
    error NothingToClaim();

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event ETHReceived(address indexed sender, uint256 amount);
    event ETHAllocated(address indexed recipient, uint256 amount);
    event ETHClaimed(address indexed recipient, uint256 amount);
    event TokenAllocated(address indexed token, address indexed recipient, uint256 amount);
    event TokenClaimed(address indexed token, address indexed recipient, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param admin    DEFAULT_ADMIN_ROLE — should be the deployer / multisig initially.
    /// @param timelock SPENDER_ROLE — the TimelockController address.
    constructor(address admin, address timelock) {
        if (admin == address(0) || timelock == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SPENDER_ROLE, timelock);
    }

    /*//////////////////////////////////////////////////////////////
                       RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }

    /*//////////////////////////////////////////////////////////////
                       ALLOCATION (Timelock only)
    //////////////////////////////////////////////////////////////*/

    /// @notice Allocate ETH grant to a recipient. Must be called via Timelock proposal.
    function allocateETH(address recipient, uint256 amount) external onlyRole(SPENDER_ROLE) {
        // ── Checks ──────────────────────────────────────────────
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert InsufficientBalance(amount, address(this).balance);

        // ── Effects ─────────────────────────────────────────────
        pendingETH[recipient] += amount;

        emit ETHAllocated(recipient, amount);
    }

    /// @notice Allocate ERC-20 token grant to a recipient. Must be called via Timelock proposal.
    function allocateToken(address token, address recipient, uint256 amount) external onlyRole(SPENDER_ROLE) {
        // ── Checks ──────────────────────────────────────────────
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance(amount, balance);

        // ── Effects ─────────────────────────────────────────────
        pendingTokens[recipient][token] += amount;

        emit TokenAllocated(token, recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                       CLAIM (recipient pulls)
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim allocated ETH. Pull-over-push: recipient calls this, Treasury doesn't push.
    function claimETH() external nonReentrant {
        // ── Checks ──────────────────────────────────────────────
        uint256 amount = pendingETH[msg.sender];
        if (amount == 0) revert NothingToClaim();

        // ── Effects ─────────────────────────────────────────────
        pendingETH[msg.sender] = 0;

        // ── Interactions ─────────────────────────────────────────
        // No transfer/send — use call{value:} with success check.
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();

        emit ETHClaimed(msg.sender, amount);
    }

    /// @notice Claim allocated ERC-20 tokens.
    function claimToken(address token) external nonReentrant {
        // ── Checks ──────────────────────────────────────────────
        uint256 amount = pendingTokens[msg.sender][token];
        if (amount == 0) revert NothingToClaim();

        // ── Effects ─────────────────────────────────────────────
        pendingTokens[msg.sender][token] = 0;

        // ── Interactions ─────────────────────────────────────────
        IERC20(token).safeTransfer(msg.sender, amount);

        emit TokenClaimed(token, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function tokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
