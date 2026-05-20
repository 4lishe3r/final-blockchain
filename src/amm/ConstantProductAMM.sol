// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ConstantProductAMM is ERC20 {
    IERC20 public token0;
    IERC20 public token1;

    uint256 private reserve0;
    uint256 private reserve1;

    constructor(address _token0, address _token1, address admin) ERC20("AMM LP Token", "ALP") {
        require(_token0 != address(0) && _token1 != address(0), "bad token");
        require(_token0 != _token1, "same token");
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256,
        uint256,
        address to
    ) external returns (uint256 shares) {
        require(amount0Desired > 0 && amount1Desired > 0, "zero amount");

        token0.transferFrom(msg.sender, address(this), amount0Desired);
        token1.transferFrom(msg.sender, address(this), amount1Desired);

        if (totalSupply() == 0) {
            shares = amount0Desired + amount1Desired;
        } else {
            shares = (amount0Desired + amount1Desired) * totalSupply() / (reserve0 + reserve1);
        }

        reserve0 += amount0Desired;
        reserve1 += amount1Desired;

        _mint(to, shares);
    }

    function swap(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        address to
    ) external returns (uint256 amountOut) {
        require(amountIn > 0, "zero amount");
        require(tokenIn == address(token0) || tokenIn == address(token1), "invalid token");

        bool zeroForOne = tokenIn == address(token0);

        IERC20 inToken = zeroForOne ? token0 : token1;
        IERC20 outToken = zeroForOne ? token1 : token0;

        uint256 reserveIn = zeroForOne ? reserve0 : reserve1;
        uint256 reserveOut = zeroForOne ? reserve1 : reserve0;

        require(reserveIn > 0 && reserveOut > 0, "no liquidity");

        uint256 amountInWithFee = amountIn * 997;
        amountOut = (amountInWithFee * reserveOut) / ((reserveIn * 1000) + amountInWithFee);

        require(amountOut >= amountOutMin, "slippage");
        require(amountOut < reserveOut, "low liquidity");

        inToken.transferFrom(msg.sender, address(this), amountIn);
        outToken.transfer(to, amountOut);

        if (zeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }
    }
}