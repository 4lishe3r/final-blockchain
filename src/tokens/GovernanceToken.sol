// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20VotesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";

/// @title GovernanceToken  (V1)
/// @notice ERC-20 governance token with on-chain vote delegation (ERC20Votes) and gasless approvals (ERC20Permit).
///         Deployed behind a UUPS proxy so parameters can be changed in V2 without migration.
///
/// @dev Storage layout (MUST be preserved in V2):
///  ┌─────────────────────────────────────────────────────────────────┐
///  │ Slot 0-N  : OpenZeppelin upgradeable base contracts             │
///  │ SlotN+1   : AccessControlUpgradeable._roles                     │
///  │ SlotN+2   : _maxSupply                                          │
///  └─────────────────────────────────────────────────────────────────┘
///  Never insert new variables BEFORE _maxSupply in V2; only append after it.
contract GovernanceToken is
    Initializable,
    ERC20Upgradeable,
    ERC20VotesUpgradeable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Appended variables must come AFTER this point in V2+.
    uint256 public maxSupply;

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error MaxSupplyExceeded(uint256 requested, uint256 available);
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event MaxSupplyUpdated(uint256 oldMax, uint256 newMax);

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param name_       Token name (e.g. "DeFi Governance Token")
    /// @param symbol_     Token symbol (e.g. "DGT")
    /// @param maxSupply_  Hard cap on total supply (18-decimal amount)
    /// @param admin       Address that receives DEFAULT_ADMIN_ROLE, MINTER_ROLE, UPGRADER_ROLE
    function initialize(string memory name_, string memory symbol_, uint256 maxSupply_, address admin)
        external
        initializer
    {
        if (admin == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __ERC20Votes_init();
        __ERC20Permit_init(name_);
        __AccessControl_init();

        maxSupply = maxSupply_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint new tokens. Only MINTER_ROLE.
    /// @dev Checks-Effects-Interactions: state updated before any external call.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        // ── Checks ──────────────────────────────────────────────
        if (to == address(0)) revert ZeroAddress();
        uint256 available = maxSupply - totalSupply();
        if (amount > available) revert MaxSupplyExceeded(amount, available);

        // ── Effects + Interactions (ERC20._mint emits Transfer) ──
        _mint(to, amount);
    }

    /// @notice Burn tokens from caller's balance.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Update the max supply cap. Only DEFAULT_ADMIN_ROLE.
    function setMaxSupply(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMax >= totalSupply(), "New max below current supply");
        emit MaxSupplyUpdated(maxSupply, newMax);
        maxSupply = newMax;
    }

    /*//////////////////////////////////////////////////////////////
                        UUPS AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Only UPGRADER_ROLE can upgrade the implementation.
    ///      In production, UPGRADER_ROLE is held by the Timelock.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /*//////////////////////////////////////////////////////////////
                          OZ OVERRIDES
    //////////////////////////////////////////////////////////////*/

    // ERC20Votes requires clock to be block.number or block.timestamp.
    // We use block.number (default) to be consistent with Governor.
    function clock() public view override returns (uint48) {
        return uint48(block.number);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    function _update(address from, address to, uint256 value) internal virtual override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }
}
