// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/TokenizedStrategy.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

contract UniswapV3Strategy is TokenizedStrategy, IERC721Receiver {
    using SafeERC20 for IERC20;

    // Constants
    int24 public constant TICK_SPACING = 60;
    uint24 public constant POOL_FEE = 3000; // 0.3%

    // Immutables
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Pool public immutable pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    // Position state
    struct Position {
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    Position public currentPosition;

    constructor(
        address _asset,
        string memory _name,
        address _vault,
        address _positionManager,
        address _pool,
        address _feeRecipient
    ) TokenizedStrategy(_asset, _name, "uniV3", _vault, _feeRecipient) {
        positionManager = INonfungiblePositionManager(_positionManager);
        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());

        // Approve position manager
        SafeERC20.forceApprove(token0, _positionManager, type(uint256).max);
        SafeERC20.forceApprove(token1, _positionManager, type(uint256).max);
    }

    function _deployFunds(uint256 amount) internal override {
        if (amount == 0) return;

        // Get current price and tick
        (uint160 sqrtPriceX96, int24 tick,,,,,) = pool.slot0();

        // Set position range (±1% for stablecoins)
        int24 tickLower = (tick - 200) / TICK_SPACING * TICK_SPACING;
        int24 tickUpper = (tick + 200) / TICK_SPACING * TICK_SPACING;

        // Prepare mint parameters
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: POOL_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount,
            amount1Desired: amount,
            amount0Min: 0, // Add slippage protection in production
            amount1Min: 0, // Add slippage protection in production
            recipient: address(this),
            deadline: block.timestamp
        });

        // Mint new position
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = positionManager.mint(params);

        // Store position
        currentPosition = Position({tokenId: tokenId, tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity});

        // Refund excess tokens
        if (amount0 < amount) {
            token0.safeTransfer(vault, amount - amount0);
        }
        if (amount1 < amount) {
            token1.safeTransfer(vault, amount - amount1);
        }
    }

    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;

        // Calculate share of liquidity to remove
        uint128 liquidityToRemove = uint128((amount * currentPosition.liquidity) / totalAssets);

        // Decrease liquidity
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: currentPosition.tokenId,
            liquidity: liquidityToRemove,
            amount0Min: 0, // Add slippage protection in production
            amount1Min: 0, // Add slippage protection in production
            deadline: block.timestamp
        });

        (uint256 amount0, uint256 amount1) = positionManager.decreaseLiquidity(params);

        // Collect tokens
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: currentPosition.tokenId,
            recipient: address(this),
            amount0Max: uint128(amount0),
            amount1Max: uint128(amount1)
        });

        positionManager.collect(collectParams);

        // Update position state
        currentPosition.liquidity -= liquidityToRemove;

        // Transfer tokens to vault
        token0.safeTransfer(vault, amount0);
        token1.safeTransfer(vault, amount1);
    }

    function _estimateCurrentAssets() internal override returns (uint256) {
        // Get position info
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = positionManager.positions(currentPosition.tokenId);

        // Get current price
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        // Calculate total value including fees
        uint256 totalValue = _calculateTotalValue(liquidity, tokensOwed0, tokensOwed1, sqrtPriceX96);

        return totalValue;
    }

    // Helper functions
    function _calculateTotalValue(uint128 liquidity, uint128 fees0, uint128 fees1, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256)
    {
        // Implement price calculation based on your requirements
        // This is a simplified version
        return liquidity + fees0 + fees1;
    }

    // Required for IERC721Receiver
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        override
        returns (bytes4)
    {
        require(msg.sender == address(positionManager), "Not position manager");
        return this.onERC721Received.selector;
    }

    // Emergency functions
    function emergencyWithdraw() external override onlyVault {
        require(isShutdown, "Not shutdown");

        if (currentPosition.liquidity > 0) {
            // Remove all liquidity
            INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
                .DecreaseLiquidityParams({
                tokenId: currentPosition.tokenId,
                liquidity: currentPosition.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });

            positionManager.decreaseLiquidity(params);

            // Collect all tokens
            INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
                tokenId: currentPosition.tokenId,
                recipient: vault,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

            positionManager.collect(collectParams);
        }

        // Reset state
        currentPosition = Position(0, 0, 0, 0);
        totalAssets = 0;
    }
}
