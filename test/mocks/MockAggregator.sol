// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @title MockAggregator
/// @notice Chainlink AggregatorV3 mock for unit and fuzz tests.
///         Set any price, make it stale, simulate bad rounds.
contract MockAggregator is AggregatorV3Interface {
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;
    uint8 private immutable _decimals;

    constructor(uint8 dec_, int256 initialPrice) {
        _decimals = dec_;
        _answer = initialPrice;
        _updatedAt = block.timestamp;
        _roundId = 1;
    }

    // ─── Setters (test helpers) ──────────────────────────────────

    function setPrice(int256 price) external {
        _answer = price;
        _updatedAt = block.timestamp;
        _roundId++;
    }

    function setUpdatedAt(uint256 ts) external {
        _updatedAt = ts;
    }

    function setAnswer(int256 answer, uint256 updatedAt) external {
        _answer = answer;
        _updatedAt = updatedAt;
        _roundId++;
    }

    // ─── AggregatorV3Interface ───────────────────────────────────

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "MockAggregator";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _rid)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_rid, _answer, _updatedAt, _updatedAt, _rid);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
