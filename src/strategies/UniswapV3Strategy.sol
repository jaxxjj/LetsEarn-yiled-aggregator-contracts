// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/TokenizedStrategy.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UniswapV3Strategy is TokenizedStrategy {
    using SafeERC20 for IERC20;

    // Constants
    int24 public constant TICK_SPACING = 60;
    
    // Immutables
    IUniswapV3Pool public immutable pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    
    // Position state
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;

    constructor(
        address _asset,
        string memory _name,
        address _vault,
        address _pool,
        address _feeRecipient
    ) TokenizedStrategy(_asset, _name, "uniV3", _vault, _feeRecipient) {
        require(_pool != address(0), "Invalid pool");
        
        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        
        // Approve tokens
        SafeERC20.forceApprove(token0, _pool, type(uint256).max);
        SafeERC20.forceApprove(token1, _pool, type(uint256).max);
    }

    function _deployFunds(uint256 amount) internal override {
        if (amount == 0) return;
        
        // Get current price and tick
        (uint160 sqrtPriceX96, int24 tick,,,,, ) = pool.slot0();
        
        // Set position range (±1% for stablecoins)
        tickLower = (tick - 200) / TICK_SPACING * TICK_SPACING;
        tickUpper = (tick + 200) / TICK_SPACING * TICK_SPACING;
        
        // Calculate optimal liquidity
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount,
            amount
        );
        
        // Mint position
        pool.mint(
            address(this),
            tickLower,
            tickUpper,
            liquidityDelta,
            ""
        );
        
        liquidity += liquidityDelta;
    }

    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;
        
        // Calculate share of liquidity to remove
        uint128 liquidityToRemove = uint128((amount * liquidity) / totalAssets);
        
        // Remove liquidity
        (uint256 amount0, uint256 amount1) = pool.burn(
            tickLower,
            tickUpper,
            liquidityToRemove
        );
        
        // Collect tokens
        pool.collect(
            address(this),
            tickLower,
            tickUpper,
            uint128(amount0),
            uint128(amount1)
        );
        
        liquidity -= liquidityToRemove;
    }

    function _estimateCurrentAssets() internal override returns (uint256) {
        // Get position info
        (
            uint128 posLiquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = pool.positions(
            keccak256(abi.encodePacked(address(this), tickLower, tickUpper))
        );
        
        // Get current price
        (uint160 sqrtPriceX96,,,,,, ) = pool.slot0();
        
        // Calculate position value including fees
        uint256 totalValue = SqrtPriceMath.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            posLiquidity
        );
        
        return totalValue + tokensOwed0 + tokensOwed1;
    }

    // View functions
    function estimatedTotalAssets() public view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,, ) = pool.slot0();
        
        return SqrtPriceMath.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
    }

    function expectedReturn() external view returns (uint256) {
        uint256 currentValue = estimatedTotalAssets();
        return currentValue > totalAssets ? currentValue - totalAssets : 0;
    }

    // Emergency functions
    function emergencyWithdraw() external override onlyVault {
        require(isShutdown, "Not shutdown");
        
        // Remove all liquidity
        if (liquidity > 0) {
            pool.burn(tickLower, tickUpper, liquidity);
            pool.collect(
                vault,
                tickLower,
                tickUpper,
                type(uint128).max,
                type(uint128).max
            );
        }
        
        // Reset accounting
        liquidity = 0;
        totalAssets = 0;
    }
}