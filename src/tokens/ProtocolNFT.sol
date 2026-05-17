// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title ProtocolNFT
/// @notice ERC-721 membership badge minted to governance participants and early LPs.
///         Non-transferable (soulbound) after mint — satisfies ERC-721 requirement.
///
/// @dev Access Control roles:
///  • MINTER_ROLE  — can mint badges (held by Governor / Timelock in production)
///  • DEFAULT_ADMIN_ROLE — can update base URI, grant/revoke roles
contract ProtocolNFT is ERC721URIStorage, AccessControl {
    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 private _nextTokenId;
    string private _baseTokenURI;
    bool public soulbound; // if true, transfers are blocked after mint

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error Soulbound();
    error AlreadyHoldsBadge(address holder);
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event BadgeMinted(address indexed to, uint256 indexed tokenId, string uri);
    event SoulboundSet(bool enabled);
    event BaseURIUpdated(string newBaseURI);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(string memory baseURI_, address admin, bool soulbound_) ERC721("DeFi Protocol Badge", "DPB") {
        _baseTokenURI = baseURI_;
        soulbound = soulbound_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint a badge to an address. Only MINTER_ROLE.
    /// @param to      Recipient
    /// @param uri     Token metadata URI (IPFS CID recommended)
    function mint(address to, string calldata uri) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf(to) > 0) revert AlreadyHoldsBadge(to);

        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);

        emit BadgeMinted(to, tokenId, uri);
    }

    /// @notice Batch mint badges. Only MINTER_ROLE.
    function batchMint(address[] calldata recipients, string[] calldata uris)
        external
        onlyRole(MINTER_ROLE)
        returns (uint256[] memory tokenIds)
    {
        require(recipients.length == uris.length, "Length mismatch");
        tokenIds = new uint256[](recipients.length);
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            if (balanceOf(recipients[i]) > 0) revert AlreadyHoldsBadge(recipients[i]);
            uint256 id = _nextTokenId++;
            _safeMint(recipients[i], id);
            _setTokenURI(id, uris[i]);
            tokenIds[i] = id;
            emit BadgeMinted(recipients[i], id, uris[i]);
        }
    }

    function setSoulbound(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        soulbound = enabled;
        emit SoulboundSet(enabled);
    }

    function setBaseURI(string calldata newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    function totalSupply() external view returns (uint256) {
        return _nextTokenId;
    }

    /*//////////////////////////////////////////////////////////////
                          SOULBOUND OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// @dev Block transfers if soulbound. Mint (from == 0) and burn (to == 0) still allowed.
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721) returns (address from) {
        from = super._update(to, tokenId, auth);
        if (soulbound && from != address(0) && to != address(0)) {
            revert Soulbound();
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ERC-165 OVERRIDE
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721URIStorage, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
