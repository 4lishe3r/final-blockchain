// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ConstantProductAMM} from "../amm/ConstantProductAMM.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ProtocolFactory
/// @notice Deploys ConstantProductAMM pools using both CREATE and CREATE2.
///         Maintains a registry of all pools.
///
/// @dev Design pattern: Factory
///      • createPool()        uses CREATE  — address determined by factory nonce
///      • createPool2()       uses CREATE2 — deterministic address from token pair salt
///      • getPool()           returns pool for a token pair (canonical ordering applied)
///      • computePoolAddress() lets callers pre-compute the CREATE2 address off-chain
contract ProtocolFactory is AccessControl {
    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping of (token0, token1) → pool address (canonical ordering: token0 < token1)
    mapping(address => mapping(address => address)) public getPool;

    /// @notice Ordered list of all deployed pools
    address[] public allPools;

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error PoolAlreadyExists(address token0, address token1, address pool);
    error IdenticalTokens();
    error ZeroToken();

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolCreated(address indexed token0, address indexed token1, address pool, uint256 poolCount, bool create2);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POOL_CREATOR_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                          FACTORY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a new AMM pool using CREATE (nonce-based address).
    ///         Any address with POOL_CREATOR_ROLE can call this.
    /// @param tokenA First token
    /// @param tokenB Second token
    /// @return pool  Deployed pool address
    function createPool(address tokenA, address tokenB)
        external
        onlyRole(POOL_CREATOR_ROLE)
        returns (address pool)
    {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        _revertIfExists(token0, token1);

        // CREATE — address = keccak256(rlp([factory, nonce]))[12:]
        ConstantProductAMM amm = new ConstantProductAMM(token0, token1, msg.sender);
        pool = address(amm);

        _register(token0, token1, pool, false);
    }

    /// @notice Deploy a new AMM pool using CREATE2 (deterministic address).
    ///         The salt is derived from the token pair, so the address is predictable.
    /// @param tokenA First token
    /// @param tokenB Second token
    /// @return pool  Deployed pool address
    function createPool2(address tokenA, address tokenB)
        external
        onlyRole(POOL_CREATOR_ROLE)
        returns (address pool)
    {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        _revertIfExists(token0, token1);

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        // CREATE2 — address = keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]
        ConstantProductAMM amm = new ConstantProductAMM{salt: salt}(token0, token1, msg.sender);
        pool = address(amm);

        _register(token0, token1, pool, true);
    }

    /// @notice Pre-compute the address of a CREATE2 pool without deploying.
    ///         Useful for front-ends and integration tests.
    function computePoolAddress(address tokenA, address tokenB) external view returns (address predicted) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        bytes memory initCode =
            abi.encodePacked(type(ConstantProductAMM).creationCode, abi.encode(token0, token1, msg.sender));

        predicted = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(initCode))))
            )
        );
    }

    /// @notice Total number of pools deployed by this factory.
    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert IdenticalTokens();
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroToken();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _revertIfExists(address token0, address token1) internal view {
        address existing = getPool[token0][token1];
        if (existing != address(0)) revert PoolAlreadyExists(token0, token1, existing);
    }

    function _register(address token0, address token1, address pool, bool usedCreate2) internal {
        getPool[token0][token1] = pool;
        getPool[token1][token0] = pool; // reverse mapping for convenience
        allPools.push(pool);
        emit PoolCreated(token0, token1, pool, allPools.length, usedCreate2);
    }
}
