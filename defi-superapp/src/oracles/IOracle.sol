// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IOracle
/// @notice Abstraction layer over any price feed (Chainlink, mock, etc.)
/// @dev Oracle adapter pattern — all consumers depend on this interface, never on Chainlink directly.
///      Swap the implementation without touching protocol contracts.
interface IOracle {
    /// @notice Returns the USD price of the asset scaled to 18 decimals.
    /// @return price  Asset price (18 decimals)
    /// @return updatedAt Unix timestamp of the price update
    function latestPrice() external view returns (uint256 price, uint256 updatedAt);

    /// @notice Convenience: reverts if price is stale or <= 0.
    function safePrice() external view returns (uint256 price);
}
