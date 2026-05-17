// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ChainlinkOracleAdapter} from "../../src/oracles/ChainlinkOracleAdapter.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

contract ChainlinkOracleAdapterTest is Test {
    ChainlinkOracleAdapter public adapter;
    MockAggregator public aggregator;

    address public admin = makeAddr("admin");

    uint256 constant MAX_STALENESS = 3_600; // 1 hour

    function setUp() public {
        aggregator = new MockAggregator(2_000e8, 8); // $2000, 8 dec
        adapter = new ChainlinkOracleAdapter(address(aggregator), MAX_STALENESS, admin);
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsFeed() public view {
        assertEq(address(adapter.feed()), address(aggregator));
    }

    function test_Constructor_SetsMaxStaleness() public view {
        assertEq(adapter.maxStaleness(), MAX_STALENESS);
    }

    function test_Constructor_RevertIf_ZeroFeed() public {
        vm.expectRevert("Zero feed address");
        new ChainlinkOracleAdapter(address(0), MAX_STALENESS, admin);
    }

    function test_Constructor_RevertIf_ZeroStaleness() public {
        vm.expectRevert("Zero staleness");
        new ChainlinkOracleAdapter(address(aggregator), 0, admin);
    }

    /*//////////////////////////////////////////////////////////////
                        latestPrice TESTS
    //////////////////////////////////////////////////////////////*/

    function test_LatestPrice_ReturnsNormalized18Dec() public view {
        (uint256 price, uint256 updatedAt) = adapter.latestPrice();
        // 2000e8 with 8 decimals → normalized to 18 dec = 2000e18
        assertEq(price, 2_000e18);
        assertGt(updatedAt, 0);
    }

    function test_LatestPrice_RevertIf_NegativePrice() public {
        aggregator.setAnswer(-1);
        vm.expectRevert();
        adapter.latestPrice();
    }

    function test_LatestPrice_RevertIf_ZeroPrice() public {
        aggregator.setAnswer(0);
        vm.expectRevert();
        adapter.latestPrice();
    }

    function test_LatestPrice_RevertIf_InvalidRound() public {
        aggregator.setInvalidRound(true);
        vm.expectRevert();
        adapter.latestPrice();
    }

    /*//////////////////////////////////////////////////////////////
                        safePrice TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SafePrice_ReturnsPrice_WhenFresh() public view {
        uint256 price = adapter.safePrice();
        assertEq(price, 2_000e18);
    }

    function test_SafePrice_RevertIf_Stale() public {
        // Warp past the staleness window
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        vm.expectRevert();
        adapter.safePrice();
    }

    function test_SafePrice_OK_AtExactStalenessEdge() public {
        // At exactly maxStaleness, price is still valid
        vm.warp(block.timestamp + MAX_STALENESS);
        uint256 price = adapter.safePrice();
        assertEq(price, 2_000e18);
    }

    function test_SafePrice_RevertIf_NegativePrice() public {
        aggregator.setAnswer(-1);
        vm.expectRevert();
        adapter.safePrice();
    }

    /*//////////////////////////////////////////////////////////////
                    DECIMAL NORMALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Normalize_6Decimals() public {
        MockAggregator agg6 = new MockAggregator(2_000e6, 6); // 6 dec
        ChainlinkOracleAdapter a = new ChainlinkOracleAdapter(address(agg6), MAX_STALENESS, admin);
        (uint256 price,) = a.latestPrice();
        assertEq(price, 2_000e18);
    }

    function test_Normalize_18Decimals() public {
        MockAggregator agg18 = new MockAggregator(int256(2_000e18), 18);
        ChainlinkOracleAdapter a = new ChainlinkOracleAdapter(address(agg18), MAX_STALENESS, admin);
        (uint256 price,) = a.latestPrice();
        assertEq(price, 2_000e18);
    }

    function test_Normalize_20Decimals() public {
        MockAggregator agg20 = new MockAggregator(int256(2_000e20), 20);
        ChainlinkOracleAdapter a = new ChainlinkOracleAdapter(address(agg20), MAX_STALENESS, admin);
        (uint256 price,) = a.latestPrice();
        assertEq(price, 2_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                    FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SafePrice_StaleIfWarped(uint256 warpSeconds) public {
        warpSeconds = bound(warpSeconds, MAX_STALENESS + 1, 365 days);
        vm.warp(block.timestamp + warpSeconds);
        vm.expectRevert();
        adapter.safePrice();
    }

    function testFuzz_LatestPrice_NormalizesCorrectly(int256 rawPrice) public {
        rawPrice = bound(rawPrice, 1, int256(type(uint128).max));
        aggregator.setAnswer(rawPrice);
        (uint256 price,) = adapter.latestPrice();
        // 8 decimals → 18 decimals: price = rawPrice * 1e10
        assertEq(price, uint256(rawPrice) * 1e10);
    }
}
