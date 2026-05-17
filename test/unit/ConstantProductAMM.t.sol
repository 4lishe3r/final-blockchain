// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ConstantProductAMM} from "../../src/amm/ConstantProductAMM.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title ConstantProductAMM unit + fuzz + invariant tests
/// @dev Run with:  forge test --match-path test/unit/ConstantProductAMM.t.sol -vvv
///      Coverage:  forge coverage --match-path test/unit/ConstantProductAMM.t.sol
contract ConstantProductAMMTest is Test {
    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    ConstantProductAMM public amm;
    ERC20Mock public tokenA;
    ERC20Mock public tokenB;

    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");
    address public admin = makeAddr("admin");

    uint256 constant INITIAL_LIQUIDITY_A = 100_000e18;
    uint256 constant INITIAL_LIQUIDITY_B = 200_000e18;

    function setUp() public {
        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();

        amm = new ConstantProductAMM(address(tokenA), address(tokenB), admin);

        // Mint tokens to alice (LP provider) and bob (swapper)
        tokenA.mint(alice, 1_000_000e18);
        tokenB.mint(alice, 1_000_000e18);
        tokenA.mint(bob,   1_000_000e18);
        tokenB.mint(bob,   1_000_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                    HELPER: seed initial liquidity
    //////////////////////////////////////////////////////////////*/

    function _addInitialLiquidity() internal returns (uint256 shares) {
        vm.startPrank(alice);
        tokenA.approve(address(amm), INITIAL_LIQUIDITY_A);
        tokenB.approve(address(amm), INITIAL_LIQUIDITY_B);
        shares = amm.addLiquidity(INITIAL_LIQUIDITY_A, INITIAL_LIQUIDITY_B, 0, 0, alice);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    TOKEN ORDERING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TokensAreSorted() public view {
        // Regardless of constructor order, token0 < token1
        assertTrue(address(amm.token0()) < address(amm.token1()));
    }

    /*//////////////////////////////////////////////////////////////
                    ADD LIQUIDITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddLiquidity_FirstDeposit() public {
        uint256 shares = _addInitialLiquidity();

        // Shares ≈ sqrt(100_000e18 * 200_000e18) - MINIMUM_LIQUIDITY
        uint256 expectedSqrt = 141_421_356_237_309_504_880_168; // approx sqrt(2e10) * 1e18
        assertApproxEqRel(shares, expectedSqrt - amm.MINIMUM_LIQUIDITY(), 1e15); // 0.1% tolerance

        // Reserves updated
        (uint256 r0, uint256 r1) = amm.getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
    }

    function test_AddLiquidity_SubsequentDeposit() public {
        _addInitialLiquidity();

        uint256 sharesBefore = amm.totalSupply();

        vm.startPrank(bob);
        tokenA.approve(address(amm), 10_000e18);
        tokenB.approve(address(amm), 20_000e18);
        uint256 shares = amm.addLiquidity(10_000e18, 20_000e18, 0, 0, bob);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(amm.totalSupply(), sharesBefore + shares);
    }

    function test_AddLiquidity_RevertIf_ZeroAmount() public {
        vm.startPrank(alice);
        tokenA.approve(address(amm), 1000e18);
        vm.expectRevert(ConstantProductAMM.ZeroAmount.selector);
        amm.addLiquidity(0, 1000e18, 0, 0, alice);
        vm.stopPrank();
    }

    function test_AddLiquidity_RevertIf_SlippageTooHigh() public {
        _addInitialLiquidity();

        vm.startPrank(bob);
        tokenA.approve(address(amm), 10_000e18);
        tokenB.approve(address(amm), 20_000e18);

        // Demand more than we'll get
        vm.expectRevert();
        amm.addLiquidity(10_000e18, 20_000e18, 10_000e18, 20_001e18, bob);
        vm.stopPrank();
    }

    function test_AddLiquidity_MinimumLiquidityBurned() public {
        _addInitialLiquidity();
        // address(1) holds MINIMUM_LIQUIDITY permanently
        assertEq(amm.balanceOf(address(1)), amm.MINIMUM_LIQUIDITY());
    }

    /*//////////////////////////////////////////////////////////////
                    REMOVE LIQUIDITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RemoveLiquidity_Full() public {
        uint256 shares = _addInitialLiquidity();

        uint256 aliceA_before = tokenA.balanceOf(alice);
        uint256 aliceB_before = tokenB.balanceOf(alice);

        vm.startPrank(alice);
        amm.approve(address(amm), shares);
        (uint256 out0, uint256 out1) = amm.removeLiquidity(shares, 0, 0, alice);
        vm.stopPrank();

        assertGt(out0, 0);
        assertGt(out1, 0);
        assertEq(tokenA.balanceOf(alice), aliceA_before + out0);
        assertEq(tokenB.balanceOf(alice), aliceB_before + out1);
    }

    function test_RemoveLiquidity_RevertIf_ZeroShares() public {
        _addInitialLiquidity();
        vm.expectRevert(ConstantProductAMM.ZeroAmount.selector);
        amm.removeLiquidity(0, 0, 0, alice);
    }

    function test_RemoveLiquidity_RevertIf_SlippageTooHigh() public {
        uint256 shares = _addInitialLiquidity();
        vm.startPrank(alice);
        amm.approve(address(amm), shares);
        vm.expectRevert();
        amm.removeLiquidity(shares, type(uint256).max, 0, alice);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Swap_TokenAForTokenB() public {
        _addInitialLiquidity();

        (uint256 r0, uint256 r1) = amm.getReserves();
        address tok0 = address(amm.token0());

        uint256 amountIn = 1_000e18;
        uint256 expectedOut = amm.getAmountOut(amountIn, r0, r1);

        uint256 bobBefore = amm.token1().balanceOf(bob);

        vm.startPrank(bob);
        amm.token0().approve(address(amm), amountIn);
        uint256 out = amm.swap(tok0, amountIn, expectedOut, bob);
        vm.stopPrank();

        assertEq(out, expectedOut);
        assertEq(amm.token1().balanceOf(bob), bobBefore + out);
    }

    function test_Swap_RevertIf_InvalidToken() public {
        _addInitialLiquidity();
        vm.startPrank(bob);
        vm.expectRevert(ConstantProductAMM.InvalidToken.selector);
        amm.swap(address(0xdead), 1000e18, 0, bob);
        vm.stopPrank();
    }

    function test_Swap_RevertIf_ZeroInput() public {
        _addInitialLiquidity();
        vm.startPrank(bob);
        vm.expectRevert(ConstantProductAMM.InsufficientInputAmount.selector);
        amm.swap(address(amm.token0()), 0, 0, bob);
        vm.stopPrank();
    }

    function test_Swap_RevertIf_SlippageTooHigh() public {
        _addInitialLiquidity();
        uint256 amountIn = 1_000e18;
        vm.startPrank(bob);
        amm.token0().approve(address(amm), amountIn);
        vm.expectRevert();
        amm.swap(address(amm.token0()), amountIn, type(uint256).max, bob);
        vm.stopPrank();
    }

    function test_Swap_RevertIf_NoLiquidity() public {
        vm.startPrank(bob);
        amm.token0().approve(address(amm), 1000e18);
        vm.expectRevert(ConstantProductAMM.InsufficientLiquidity.selector);
        amm.swap(address(amm.token0()), 1000e18, 0, bob);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                      PAUSABLE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause_BlocksSwap() public {
        _addInitialLiquidity();
        vm.prank(admin);
        amm.pause();

        vm.startPrank(bob);
        amm.token0().approve(address(amm), 1000e18);
        vm.expectRevert();
        amm.swap(address(amm.token0()), 1000e18, 0, bob);
        vm.stopPrank();
    }

    function test_Unpause_AllowsSwap() public {
        _addInitialLiquidity();
        vm.prank(admin);
        amm.pause();
        vm.prank(admin);
        amm.unpause();

        vm.startPrank(bob);
        amm.token0().approve(address(amm), 1000e18);
        uint256 out = amm.swap(address(amm.token0()), 1000e18, 0, bob);
        vm.stopPrank();

        assertGt(out, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnlyPauserCanPause() public {
        vm.expectRevert();
        vm.prank(alice);
        amm.pause();
    }

    /*//////////////////////////////////////////////////////////////
                    GAS BENCHMARK: Yul vs Solidity sqrt
    //////////////////////////////////////////////////////////////*/

    /// @dev Run with:  forge test --match-test test_GasBenchmark_Sqrt -vvv --gas-report
    function test_GasBenchmark_Sqrt() public view {
        uint256 input = 123_456_789_012_345_678_901_234_567;

        uint256 gasBefore = gasleft();
        uint256 resultYul = _sqrtYul(input);
        uint256 gasYul = gasBefore - gasleft();

        gasBefore = gasleft();
        uint256 resultSolidity = _sqrtSolidity(input);
        uint256 gasSol = gasBefore - gasleft();

        assertEq(resultYul, resultSolidity, "Results must match");
        console2.log("Yul sqrt gas:      ", gasYul);
        console2.log("Solidity sqrt gas: ", gasSol);
        console2.log("Savings:           ", gasSol > gasYul ? gasSol - gasYul : 0);
    }

    function _sqrtYul(uint256 y) internal pure returns (uint256 z) {
        assembly {
            switch gt(y, 3)
            case 1 {
                z := y
                let x := div(add(y, 1), 2)
                for {} lt(x, z) {} {
                    z := x
                    x := div(add(div(y, x), x), 2)
                }
            }
            case 0 { z := gt(y, 0) }
        }
    }

    function _sqrtSolidity(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

/*//////////////////////////////////////////////////////////////
                    FUZZ TEST CONTRACT
//////////////////////////////////////////////////////////////*/

/// @dev Separated contract so Foundry treats it as a fuzz suite.
///      forge test --match-contract ConstantProductAMMFuzz -vvv
contract ConstantProductAMMFuzz is Test {
    ConstantProductAMM public amm;
    ERC20Mock public token0;
    ERC20Mock public token1;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address admin = makeAddr("admin");

    function setUp() public {
        ERC20Mock tA = new ERC20Mock();
        ERC20Mock tB = new ERC20Mock();
        amm = new ConstantProductAMM(address(tA), address(tB), admin);
        token0 = ERC20Mock(address(amm.token0()));
        token1 = ERC20Mock(address(amm.token1()));

        token0.mint(alice, type(uint128).max);
        token1.mint(alice, type(uint128).max);
        token0.mint(bob,   type(uint128).max);
        token1.mint(bob,   type(uint128).max);

        // Seed 100k/200k liquidity
        vm.startPrank(alice);
        token0.approve(address(amm), 100_000e18);
        token1.approve(address(amm), 200_000e18);
        amm.addLiquidity(100_000e18, 200_000e18, 0, 0, alice);
        vm.stopPrank();
    }

    /// @notice Fuzz: swapping any amount in [1, reserve/2] never breaks k.
    function testFuzz_Swap_KNeverDecreases(uint256 amountIn) public {
        (uint256 r0Before, uint256 r1Before) = amm.getReserves();
        amountIn = bound(amountIn, 1, r0Before / 2);

        uint256 kBefore = r0Before * r1Before;

        vm.startPrank(bob);
        token0.approve(address(amm), amountIn);
        amm.swap(address(token0), amountIn, 0, bob);
        vm.stopPrank();

        (uint256 r0After, uint256 r1After) = amm.getReserves();
        uint256 kAfter = r0After * r1After;

        assertGe(kAfter, kBefore, "k must not decrease after swap");
    }

    /// @notice Fuzz: LP shares minted are proportional to deposit.
    function testFuzz_AddLiquidity_SharesProportional(uint256 extra0) public {
        extra0 = bound(extra0, 1e15, 10_000e18);
        uint256 extra1 = extra0 * 2; // maintain 1:2 ratio

        (uint256 r0, uint256 r1) = amm.getReserves();
        uint256 totalSupply = amm.totalSupply();

        uint256 expectedShares = (extra0 * totalSupply) / r0;

        vm.startPrank(bob);
        token0.approve(address(amm), extra0);
        token1.approve(address(amm), extra1);
        uint256 shares = amm.addLiquidity(extra0, extra1, 0, 0, bob);
        vm.stopPrank();

        // Allow 1 wei rounding
        assertApproxEqAbs(shares, expectedShares, 1);
    }

    /// @notice Fuzz: removing any valid share amount returns proportional assets.
    function testFuzz_RemoveLiquidity_Proportional(uint256 sharePercent) public {
        sharePercent = bound(sharePercent, 1, 99);

        uint256 aliceShares = amm.balanceOf(alice);
        uint256 sharesToRemove = (aliceShares * sharePercent) / 100;
        vm.assume(sharesToRemove > 0);

        (uint256 r0, uint256 r1) = amm.getReserves();
        uint256 totalSupply = amm.totalSupply();

        uint256 expectedOut0 = (sharesToRemove * r0) / totalSupply;
        uint256 expectedOut1 = (sharesToRemove * r1) / totalSupply;

        vm.startPrank(alice);
        amm.approve(address(amm), sharesToRemove);
        (uint256 out0, uint256 out1) = amm.removeLiquidity(sharesToRemove, 0, 0, alice);
        vm.stopPrank();

        assertApproxEqAbs(out0, expectedOut0, 1);
        assertApproxEqAbs(out1, expectedOut1, 1);
    }

    /// @notice Fuzz: getAmountOut is always strictly less than reserveOut.
    function testFuzz_GetAmountOut_NeverExceedsReserve(uint256 amountIn) public view {
        (uint256 r0, uint256 r1) = amm.getReserves();
        amountIn = bound(amountIn, 1, r0 - 1);
        uint256 out = amm.getAmountOut(amountIn, r0, r1);
        assertLt(out, r1, "Output must be < reserveOut");
    }
}

/*//////////////////////////////////////////////////////////////
                INVARIANT HANDLER + TEST
//////////////////////////////////////////////////////////////*/

/// @dev Invariant: k never decreases after any swap.
///      forge test --match-contract AMMInvariantTest
contract AMMInvariantHandler is Test {
    ConstantProductAMM public amm;
    ERC20Mock public token0;
    ERC20Mock public token1;

    address actor = makeAddr("actor");

    constructor(ConstantProductAMM _amm) {
        amm = _amm;
        token0 = ERC20Mock(address(_amm.token0()));
        token1 = ERC20Mock(address(_amm.token1()));
        token0.mint(actor, type(uint128).max);
        token1.mint(actor, type(uint128).max);
    }

    function swap0For1(uint256 amountIn) external {
        (uint256 r0,) = amm.getReserves();
        if (r0 == 0) return;
        amountIn = bound(amountIn, 1, r0 / 2);
        vm.startPrank(actor);
        token0.approve(address(amm), amountIn);
        try amm.swap(address(token0), amountIn, 0, actor) {} catch {}
        vm.stopPrank();
    }

    function swap1For0(uint256 amountIn) external {
        (, uint256 r1) = amm.getReserves();
        if (r1 == 0) return;
        amountIn = bound(amountIn, 1, r1 / 2);
        vm.startPrank(actor);
        token1.approve(address(amm), amountIn);
        try amm.swap(address(token1), amountIn, 0, actor) {} catch {}
        vm.stopPrank();
    }
}

contract AMMInvariantTest is Test {
    ConstantProductAMM public amm;
    AMMInvariantHandler public handler;

    function setUp() public {
        ERC20Mock tA = new ERC20Mock();
        ERC20Mock tB = new ERC20Mock();
        address admin = makeAddr("admin");
        amm = new ConstantProductAMM(address(tA), address(tB), admin);

        // Seed liquidity
        address alice = makeAddr("alice");
        tA.mint(alice, 100_000e18);
        tB.mint(alice, 200_000e18);
        vm.startPrank(alice);
        tA.approve(address(amm), 100_000e18);
        tB.approve(address(amm), 200_000e18);
        amm.addLiquidity(100_000e18, 200_000e18, 0, 0, alice);
        vm.stopPrank();

        handler = new AMMInvariantHandler(amm);
        targetContract(address(handler));
    }

    /// @notice k = reserve0 * reserve1 must never decrease after any swap.
    function invariant_K_NeverDecreases() public view {
        (uint256 r0, uint256 r1) = amm.getReserves();
        // k_initial = 100_000e18 * 200_000e18
        uint256 k_initial = 100_000e18 * 200_000e18;
        uint256 k_current = r0 * r1;
        assertGe(k_current, k_initial, "k decreased!");
    }

    /// @notice Total LP supply never goes below MINIMUM_LIQUIDITY (burned on first mint).
    function invariant_TotalSupplyAboveMinimum() public view {
        assertGe(amm.totalSupply(), amm.MINIMUM_LIQUIDITY());
    }
}
