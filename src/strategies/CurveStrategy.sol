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
    function balances(uint256) external view returns (uint256);
}

interface ICurveGauge {
    function deposit(uint256 _value) external;
    function withdraw(uint256 _value) external;
    function balanceOf(address) external view returns (uint256);
    function claim_rewards() external;
}

interface ICurveMinter {
    function mint(address gauge_addr) external;
}

contract CurveStrategy is TokenizedStrategy {
    using SafeERC20 for IERC20;

    // Curve contracts
    ICurvePool public constant POOL = ICurvePool(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7); // DAI/USDC Pool
    ICurveGauge public constant GAUGE = ICurveGauge(0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A);
    ICurveMinter public constant MINTER = ICurveMinter(0xd061D61a4d941c39E5453435B6345Dc261C2fcE0);
    IERC20 public constant CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public constant LP_TOKEN = IERC20(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);

    // Strategy state
    uint256 public totalLpTokens;
    int128 public constant ASSET_INDEX = 1; // Index of our asset in the pool (USDC = 1)
    uint256 public slippageProtection = 50; // 0.5%

    constructor(
        address _asset,
        string memory _name,
        address _vault,
        address _manager
    ) TokenizedStrategy(_asset, _name, _vault, _manager) {
        // Approve pool and gauge
        IERC20(_asset).safeApprove(address(POOL), type(uint256).max);
        LP_TOKEN.safeApprove(address(GAUGE), type(uint256).max);
    }

    function _deployFunds(uint256 amount) internal override {
        // Calculate minimum LP tokens to receive
        uint256 minLpAmount = _estimateMinLpTokens(amount);
        
        // Add liquidity to Curve pool
        uint256[2] memory amounts;
        amounts[ASSET_INDEX] = amount;
        POOL.add_liquidity(amounts, minLpAmount);
        
        // Stake LP tokens in gauge
        uint256 lpBalance = LP_TOKEN.balanceOf(address(this));
        GAUGE.deposit(lpBalance);
        
        // Update total LP tokens
        totalLpTokens += lpBalance;
    }

    function _freeFunds(uint256 amount) internal override {
        // Calculate LP tokens needed
        uint256 lpTokensNeeded = _calculateLpTokensForWithdrawal(amount);
        require(lpTokensNeeded <= totalLpTokens, "Insufficient LP tokens");
        
        // Withdraw from gauge
        GAUGE.withdraw(lpTokensNeeded);
        
        // Remove liquidity from pool
        uint256 minAmount = amount * (10000 - slippageProtection) / 10000;
        POOL.remove_liquidity_one_coin(lpTokensNeeded, ASSET_INDEX, minAmount);
        
        // Update total LP tokens
        totalLpTokens -= lpTokensNeeded;
    }

    function _estimateCurrentAssets() internal view override returns (uint256) {
        // Get gauge balance
        uint256 gaugeBalance = GAUGE.balanceOf(address(this));
        if (gaugeBalance == 0) return 0;
        
        // Calculate value in asset terms
        return POOL.calc_withdraw_one_coin(gaugeBalance, ASSET_INDEX);
    }

    function _harvestAndReport() internal override returns (uint256) {
        // Claim CRV rewards
        GAUGE.claim_rewards();
        MINTER.mint(address(GAUGE));
        
        // Sell CRV rewards for asset
        uint256 crvBalance = CRV.balanceOf(address(this));
        if (crvBalance > 0) {
            _sellRewards(crvBalance);
        }
        
        // Return total assets
        return _estimateCurrentAssets();
    }

    function _emergencyWithdraw() internal override {
        // Withdraw everything from gauge
        uint256 gaugeBalance = GAUGE.balanceOf(address(this));
        if (gaugeBalance > 0) {
            GAUGE.withdraw(gaugeBalance);
        }
        
        // Remove all liquidity
        uint256 lpBalance = LP_TOKEN.balanceOf(address(this));
        if (lpBalance > 0) {
            POOL.remove_liquidity_one_coin(lpBalance, ASSET_INDEX, 0);
        }
        
        // Reset state
        totalLpTokens = 0;
    }

    // Helper functions
    function _estimateMinLpTokens(uint256 amount) internal view returns (uint256) {
        // Simple estimation based on virtual price
        uint256 virtualPrice = POOL.get_virtual_price();
        uint256 expectedLp = (amount * 1e18) / virtualPrice;
        return expectedLp * (10000 - slippageProtection) / 10000;
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

    function _sellRewards(uint256 amount) internal {
        // Implement reward selling logic here
        // This would typically involve using a DEX to swap CRV for the asset
    }

    // Admin functions
    function setSlippageProtection(uint256 _slippage) external onlyManager {
        require(_slippage <= 1000, "Slippage too high"); // Max 10%
        slippageProtection = _slippage;
    }
} 