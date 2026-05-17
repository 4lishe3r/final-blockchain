// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ConstantProductAMM
/// @notice x·y = k constant-product AMM with 0.3 % swap fee and ERC-20 LP tokens.
///         Built from scratch (no Uniswap fork). Designed for the DeFi Super-App capstone.
///
/// @dev Security properties:
///  • Checks-Effects-Interactions: state updated before any external token transfer.
///  • ReentrancyGuard on every public state-changing function.
///  • SafeERC20 for all ERC-20 interactions (handles non-standard tokens).
///  • No tx.origin auth. No block.timestamp randomness. No transfer/send.
///  • MINIMUM_LIQUIDITY burned to address(1) on first mint → prevents inflation attack.
///  • Pausable circuit breaker (PAUSER_ROLE → Timelock in production).
///
/// @dev Yul assembly:
///  • _sqrt() implements the Babylonian method in inline Yul.
///    Benchmarked 15–20 % cheaper than the equivalent Solidity loop
///    (see test/unit/AMMGasBenchmark.t.sol).
///
/// @dev Design patterns used (documented in Architecture doc §4):
///  • Checks-Effects-Interactions
///  • ReentrancyGuard
///  • Pull-over-push (LP fees accrue in reserves; LPs pull via removeLiquidity)
///  • Pausable / Circuit Breaker
///  • Access Control
contract ConstantProductAMM is ERC20, ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant FEE_NUMERATOR = 997; // 0.3 % fee  →  amountIn * 997 / 1000
    uint256 public constant FEE_DENOMINATOR = 1000;
    uint256 public constant MINIMUM_LIQUIDITY = 1_000; // LP tokens burned on first mint

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 private reserve0;
    uint256 private reserve1;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InsufficientLiquidity();
    error InsufficientOutputAmount(uint256 got, uint256 min);
    error InsufficientInputAmount();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InvalidToken();
    error ZeroAmount();
    error SameTokens();
    error KInvariantViolated(uint256 kBefore, uint256 kAfter);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Swap(
        address indexed sender,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        address indexed to
    );
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event ReservesUpdated(uint256 reserve0, uint256 reserve1);

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _token0   First token in the pair (address must be < _token1 for canonical ordering)
    /// @param _token1   Second token in the pair
    /// @param admin     Receives DEFAULT_ADMIN_ROLE and PAUSER_ROLE
    constructor(address _token0, address _token1, address admin) ERC20("AMM LP Token", "ALP") {
        if (_token0 == _token1) revert SameTokens();
        if (_token0 == address(0) || _token1 == address(0)) revert InvalidToken();

        // Canonical ordering: sort so token0 < token1
        if (_token0 > _token1) (_token0, _token1) = (_token1, _token0);

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Add liquidity to the pool and receive LP tokens.
    /// @param amount0Desired  Token0 amount caller wants to deposit
    /// @param amount1Desired  Token1 amount caller wants to deposit
    /// @param amount0Min      Minimum token0 accepted (slippage protection)
    /// @param amount1Min      Minimum token1 accepted (slippage protection)
    /// @param to              Recipient of LP tokens
    /// @return shares         LP tokens minted
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        // ── Checks ──────────────────────────────────────────────
        if (amount0Desired == 0 || amount1Desired == 0) revert ZeroAmount();

        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;
        uint256 _totalSupply = totalSupply();

        uint256 amount0;
        uint256 amount1;

        if (_totalSupply == 0) {
            // First deposit: accept desired amounts as-is
            amount0 = amount0Desired;
            amount1 = amount1Desired;
        } else {
            // Subsequent deposits: maintain the current ratio
            uint256 amount1Optimal = (amount0Desired * _reserve1) / _reserve0;
            if (amount1Optimal <= amount1Desired) {
                amount0 = amount0Desired;
                amount1 = amount1Optimal;
            } else {
                uint256 amount0Optimal = (amount1Desired * _reserve0) / _reserve1;
                amount0 = amount0Optimal;
                amount1 = amount1Desired;
            }
        }

        if (amount0 < amount0Min) revert InsufficientOutputAmount(amount0, amount0Min);
        if (amount1 < amount1Min) revert InsufficientOutputAmount(amount1, amount1Min);

        // ── Effects ─────────────────────────────────────────────
        if (_totalSupply == 0) {
            // Geometric mean of deposits minus MINIMUM_LIQUIDITY (inflation-attack prevention)
            shares = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            if (shares == 0) revert InsufficientLiquidityMinted();
            _mint(address(1), MINIMUM_LIQUIDITY); // permanent lock
        } else {
            shares = _min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
            if (shares == 0) revert InsufficientLiquidityMinted();
        }

        _mint(to, shares);
        _updateReserves(_reserve0 + amount0, _reserve1 + amount1);

        // ── Interactions ─────────────────────────────────────────
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        emit LiquidityAdded(to, amount0, amount1, shares);
    }

    /// @notice Burn LP tokens and withdraw the proportional share of reserves.
    /// @param shares      LP tokens to burn
    /// @param amount0Min  Minimum token0 to receive (slippage protection)
    /// @param amount1Min  Minimum token1 to receive (slippage protection)
    /// @param to          Recipient of underlying tokens
    /// @return amount0    Token0 returned
    /// @return amount1    Token1 returned
    function removeLiquidity(uint256 shares, uint256 amount0Min, uint256 amount1Min, address to)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amount0, uint256 amount1)
    {
        // ── Checks ──────────────────────────────────────────────
        if (shares == 0) revert ZeroAmount();
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) revert InsufficientLiquidity();

        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;

        amount0 = (shares * _reserve0) / _totalSupply;
        amount1 = (shares * _reserve1) / _totalSupply;

        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
        if (amount0 < amount0Min) revert InsufficientOutputAmount(amount0, amount0Min);
        if (amount1 < amount1Min) revert InsufficientOutputAmount(amount1, amount1Min);

        // ── Effects ─────────────────────────────────────────────
        _burn(msg.sender, shares);
        _updateReserves(_reserve0 - amount0, _reserve1 - amount1);

        // ── Interactions ─────────────────────────────────────────
        token0.safeTransfer(to, amount0);
        token1.safeTransfer(to, amount1);

        emit LiquidityRemoved(to, amount0, amount1, shares);
    }

    /*//////////////////////////////////////////////////////////////
                              SWAP FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Swap an exact amount of tokenIn for at least amountOutMin of the other token.
    /// @param tokenIn      Address of the input token (must be token0 or token1)
    /// @param amountIn     Exact amount of tokenIn to send
    /// @param amountOutMin Minimum output accepted (slippage protection)
    /// @param to           Recipient of output tokens
    /// @return amountOut   Actual amount of output token sent
    function swap(address tokenIn, uint256 amountIn, uint256 amountOutMin, address to)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        // ── Checks ──────────────────────────────────────────────
        if (amountIn == 0) revert InsufficientInputAmount();
        if (tokenIn != address(token0) && tokenIn != address(token1)) revert InvalidToken();

        bool zeroForOne = tokenIn == address(token0);
        (IERC20 tokenInContract, IERC20 tokenOutContract, uint256 reserveIn, uint256 reserveOut) = zeroForOne
            ? (token0, token1, reserve0, reserve1)
            : (token1, token0, reserve1, reserve0);

        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        // ── Compute output (with fee) ────────────────────────────
        //   amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);

        if (amountOut == 0) revert InsufficientOutputAmount(0, amountOutMin);
        if (amountOut < amountOutMin) revert InsufficientOutputAmount(amountOut, amountOutMin);
        if (amountOut >= reserveOut) revert InsufficientLiquidity();

        // ── Effects ─────────────────────────────────────────────
        uint256 newReserveIn = reserveIn + amountIn;
        uint256 newReserveOut = reserveOut - amountOut;

        // k-invariant sanity check (accounts for fee going to LPs)
        // k_after >= k_before  because fee stays in pool
        uint256 kBefore = reserveIn * reserveOut;
        uint256 kAfter = newReserveIn * newReserveOut;
        if (kAfter < kBefore) revert KInvariantViolated(kBefore, kAfter);

        if (zeroForOne) {
            _updateReserves(newReserveIn, newReserveOut);
        } else {
            _updateReserves(newReserveOut, newReserveIn);
        }

        // ── Interactions ─────────────────────────────────────────
        tokenInContract.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenOutContract.safeTransfer(to, amountOut);

        emit Swap(msg.sender, tokenIn, amountIn, amountOut, to);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW / PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Current reserves of both tokens.
    function getReserves() external view returns (uint256 _reserve0, uint256 _reserve1) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
    }

    /// @notice Quote: how much tokenOut you'd receive for a given amountIn (no price impact beyond this calc).
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Update stored reserves and emit event.
    function _updateReserves(uint256 _reserve0, uint256 _reserve1) internal {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        emit ReservesUpdated(_reserve0, _reserve1);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Integer square root — Babylonian method implemented in inline Yul.
    ///      ~15-20 % cheaper than the equivalent Solidity loop.
    ///      Benchmarked in test/unit/AMMGasBenchmark.t.sol.
    ///
    ///      Algorithm:
    ///        z = y                            (initial guess)
    ///        x = (y + 1) / 2                  (first Newton step)
    ///        while x < z: z = x, x = (y/x + x) / 2
    ///      Edge cases: y ∈ {0, 1, 2, 3} → z ∈ {0, 1, 1, 1}
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
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
            // y ∈ {1, 2, 3} → sqrt rounds down to 1
            case 0 { z := gt(y, 0) }
        }
    }

    /// @dev Pure-Solidity equivalent of _sqrt — kept for gas benchmarking only.
    ///      NOT used in production paths.
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
