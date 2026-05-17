// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracle} from "./IOracle.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ChainlinkOracleAdapter
/// @notice Wraps a Chainlink AggregatorV3 feed; normalises output to 18 decimals and enforces a staleness window.
/// @dev Oracle adapter pattern — protocol contracts reference IOracle, not Chainlink directly.
///      This lets tests inject a MockAggregator without touching protocol logic.
contract ChainlinkOracleAdapter is IOracle, Ownable {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error StalePrice(uint256 updatedAt, uint256 threshold);
    error NegativeOrZeroPrice(int256 answer);
    error InvalidRound(uint80 roundId, uint80 answeredInRound);

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    AggregatorV3Interface public immutable feed;
    uint256 public immutable maxStaleness; // seconds
    uint8 private immutable _feedDecimals;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event MaxStalenessUpdated(uint256 oldVal, uint256 newVal);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _feed       Chainlink AggregatorV3Interface address
    /// @param _maxStaleness  Maximum age of price data (seconds). E.g. 3600 for ETH/USD.
    constructor(address _feed, uint256 _maxStaleness, address owner_) Ownable(owner_) {
        require(_feed != address(0), "Zero feed address");
        require(_maxStaleness > 0, "Zero staleness");
        feed = AggregatorV3Interface(_feed);
        maxStaleness = _maxStaleness;
        _feedDecimals = feed.decimals();
    }

    /*//////////////////////////////////////////////////////////////
                          IOracle IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOracle
    function latestPrice() external view override returns (uint256 price, uint256 updatedAt) {
        (uint80 roundId, int256 answer,, uint256 _updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        // Round completeness check
        if (answeredInRound < roundId) revert InvalidRound(roundId, answeredInRound);
        if (answer <= 0) revert NegativeOrZeroPrice(answer);

        price = _normalise(uint256(answer));
        updatedAt = _updatedAt;
    }

    /// @inheritdoc IOracle
    /// @dev Reverts if price is stale. Use this in any function that acts on the price.
    function safePrice() external view override returns (uint256 price) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        if (answeredInRound < roundId) revert InvalidRound(roundId, answeredInRound);
        if (answer <= 0) revert NegativeOrZeroPrice(answer);

        // ─── Staleness check ────────────────────────────────────────────
        uint256 age = block.timestamp - updatedAt;
        if (age > maxStaleness) revert StalePrice(updatedAt, block.timestamp - maxStaleness);

        price = _normalise(uint256(answer));
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Normalises a feed answer to 18 decimals.
    function _normalise(uint256 raw) internal view returns (uint256) {
        uint8 dec = _feedDecimals;
        if (dec < 18) return raw * 10 ** (18 - dec);
        if (dec > 18) return raw / 10 ** (dec - 18);
        return raw;
    }
}
