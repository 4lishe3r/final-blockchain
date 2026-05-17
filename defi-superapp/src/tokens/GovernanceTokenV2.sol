// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GovernanceToken} from "./GovernanceToken.sol";

/// @title GovernanceTokenV2
/// @notice V2 upgrade of GovernanceToken — adds transfer tax to fund the Treasury.
///
/// @dev UUPS Upgrade safety checklist:
///  1. ✅ All V1 storage variables preserved in the same slot order.
///  2. ✅ New variable `transferTaxBps` appended AFTER V1 storage (slot N+3).
///  3. ✅ `treasury` appended after `transferTaxBps` (slot N+4).
///  4. ✅ No initializer clash — uses reinitializer(2).
///  5. ✅ _authorizeUpgrade still guarded by UPGRADER_ROLE.
///
/// @dev Storage layout (append-only, never reorder):
///  ┌───────────────────────────────────────────────────────────┐
///  │  [V1 slots: ERC20, ERC20Votes, ERC20Permit, AC, UUPS]    │
///  │  maxSupply          (V1, slot preserved)                  │
///  │  transferTaxBps     (V2, NEW — appended here)             │
///  │  treasury           (V2, NEW — appended here)             │
///  └───────────────────────────────────────────────────────────┘
///
/// @dev To upgrade on-chain:
///  1. Deploy GovernanceTokenV2 implementation.
///  2. Create a Governor proposal: proxy.upgradeToAndCall(newImpl, initV2Data)
///  3. After Timelock delay, execute.
///  4. Verify via post-deployment script (script/verify.s.sol).
contract GovernanceTokenV2 is GovernanceToken {
    /*//////////////////////////////////////////////////////////////
                          V2 STORAGE (appended)
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer tax in basis points (100 = 1%). Max 500 (5%).
    uint256 public transferTaxBps;

    /// @notice Treasury address that receives the tax.
    address public treasury;

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error TaxTooHigh(uint256 bps);
    error ZeroTreasury();

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event TransferTaxUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    /*//////////////////////////////////////////////////////////////
                          V2 INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @param taxBps_    Initial transfer tax in bps (0 = no tax)
    /// @param treasury_  Treasury address to receive tax
    /// @dev reinitializer(2) ensures this can only be called once on V2.
    function initializeV2(uint256 taxBps_, address treasury_) external reinitializer(2) {
        if (taxBps_ > 500) revert TaxTooHigh(taxBps_);
        if (treasury_ == address(0)) revert ZeroTreasury();
        transferTaxBps = taxBps_;
        treasury = treasury_;
    }

    /*//////////////////////////////////////////////////////////////
                          V2 ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setTransferTax(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > 500) revert TaxTooHigh(newBps);
        emit TransferTaxUpdated(transferTaxBps, newBps);
        transferTaxBps = newBps;
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroTreasury();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /*//////////////////////////////////////////////////////////////
                    V2 OVERRIDE: transfer tax hook
    //////////////////////////////////////////////////////////////*/

    /// @dev Intercepts all transfers. If tax > 0, deducts from amount and sends to treasury.
    ///      Mint (from == 0) and burn (to == 0) are exempt from tax.
    function _update(address from, address to, uint256 value)
        internal
        override
    {
        uint256 tax = 0;
        if (from != address(0) && to != address(0) && transferTaxBps > 0 && treasury != address(0)) {
            tax = (value * transferTaxBps) / 10_000;
        }

        if (tax > 0) {
            // Send tax to treasury first, then remainder to recipient
            super._update(from, treasury, tax);
            super._update(from, to, value - tax);
        } else {
            super._update(from, to, value);
        }
    }
}
