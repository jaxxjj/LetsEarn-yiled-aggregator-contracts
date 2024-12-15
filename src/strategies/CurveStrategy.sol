// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/TokenizedStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICurvePool {
    function add_liquidity(uint256[2] memory amounts, uint256 min_mint_amount) external;
    function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 min_amount) external;
    function calc_withdraw_one_coin(uint256 _token_amount, int128 i) external view returns (uint256);
    function get_virtual_price() external view returns (uint256);
}

interface ICurveGauge {
    function deposit(uint256 _value) external;
    function withdraw(uint256 _value) external;
    function balanceOf(address) external view returns (uint256);
    function claim_rewards() external;
}

contract CurveStrategy is TokenizedStrategy {
    using SafeERC20 for IERC20;

    // Immutable addresses
    ICurvePool public immutable POOL;
    ICurveGauge public immutable GAUGE;
    IERC20 public immutable LP_TOKEN;
    int128 public immutable ASSET_INDEX;

    // Strategy state
    uint256 public totalLpTokens;

    constructor(
        address _asset,
        string memory _name,
        address _vault,
        address _pool,
        address _gauge,
        int128 _assetIndex,
        address _manager,
        address _performanceFeeRecipient
    ) TokenizedStrategy(_asset, _name, "cStrat", _vault, _performanceFeeRecipient) {
        POOL = ICurvePool(_pool);
        GAUGE = ICurveGauge(_gauge);
        LP_TOKEN = IERC20(_pool);
        ASSET_INDEX = _assetIndex;

        // Approve pool and gauge
        IERC20(_asset).forceApprove(_pool, type(uint256).max);
        IERC20(_pool).forceApprove(_gauge, type(uint256).max);
    }

    function _deployFunds(uint256 amount) internal override {
        if (amount == 0) return;

        // Add liquidity to Curve pool
        uint256[2] memory amounts;
        amounts[uint256(uint128(ASSET_INDEX))] = amount;
        POOL.add_liquidity(amounts, 0);

        // Stake LP tokens in gauge
        uint256 lpBalance = LP_TOKEN.balanceOf(address(this));
        if (lpBalance > 0) {
            GAUGE.deposit(lpBalance);
            totalLpTokens += lpBalance;
        }
    }

    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;

        // Calculate LP tokens needed
        uint256 lpTokensNeeded = _calculateLpTokensForWithdrawal(amount);
        require(lpTokensNeeded <= totalLpTokens, "Insufficient LP tokens");

        // Withdraw from gauge
        GAUGE.withdraw(lpTokensNeeded);
        totalLpTokens -= lpTokensNeeded;

        // Remove liquidity from pool
        POOL.remove_liquidity_one_coin(lpTokensNeeded, ASSET_INDEX, 0);
    }

    function _estimateCurrentAssets() internal override returns (uint256) {
        if (totalLpTokens == 0) return 0;
        
        // Claim rewards if any
        if (totalLpTokens > 0) {
            GAUGE.claim_rewards();
        }
        
        return POOL.calc_withdraw_one_coin(totalLpTokens, ASSET_INDEX);
    }

    function emergencyWithdraw() external override onlyVault {
        require(isShutdown, "Not shutdown");
        
        // Withdraw all LP tokens from gauge
        uint256 lpBalance = totalLpTokens;
        if (lpBalance > 0) {
            GAUGE.withdraw(lpBalance);
            totalLpTokens = 0;
            POOL.remove_liquidity_one_coin(lpBalance, ASSET_INDEX, 0);
        }

        // Transfer withdrawn assets to vault
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance > 0) {
            IERC20(asset).safeTransfer(vault, balance);
        }
    }

    function _calculateLpTokensForWithdrawal(uint256 amount) internal view returns (uint256) {
        // Binary search for required LP tokens
        uint256 low = 0;
        uint256 high = totalLpTokens;
        
        while (low < high) {
            uint256 mid = (low + high) / 2;
            uint256 assetAmount = POOL.calc_withdraw_one_coin(mid, ASSET_INDEX);
            
            if (assetAmount < amount) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        
        return high;
    }
} 