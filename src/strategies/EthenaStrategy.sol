// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/TokenizedStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

interface IStakedUSDeV2 {
    function stake(uint256 assets, address receiver) external returns (uint256 shares);
    function cooldownAssets(uint256 assets) external returns (uint256 shares);
    function unstake(address receiver) external;
    function cooldowns(address account) external view returns (uint104 cooldownEnd, uint152 underlyingAmount);
}

contract EthenaStrategy is TokenizedStrategy {
    using SafeERC20 for IERC20;

    // Immutable addresses
    ICurvePool public immutable CURVE_POOL;
    IStakedUSDeV2 public immutable STAKED_USDE;
    IERC20 public immutable USDE;
    int128 public immutable ASSET_INDEX;
    int128 public immutable USDE_INDEX;

    // Strategy state
    uint256 public totalStaked;
    mapping(uint256 => uint256) public cooldownAmounts; // cooldownEnd => amount
    uint256 public constant CURVE_SLIPPAGE = 50; // 0.5%
    
    constructor(
        address _asset,
        string memory _name,
        address _vault,
        address _curvePool,
        address _stakedUsde,
        address _usde,
        int128 _assetIndex,
        int128 _usdeIndex,
        address _performanceFeeRecipient
    ) TokenizedStrategy(_asset, _name, "eStrat", _vault, _performanceFeeRecipient) {
        CURVE_POOL = ICurvePool(_curvePool);
        STAKED_USDE = IStakedUSDeV2(_stakedUsde);
        USDE = IERC20(_usde);
        ASSET_INDEX = _assetIndex;
        USDE_INDEX = _usdeIndex;

        // Approve tokens
        IERC20(_asset).forceApprove(_curvePool, type(uint256).max);
        IERC20(_usde).forceApprove(_stakedUsde, type(uint256).max);
    }

    function _deployFunds(uint256 amount) internal override {
        if (amount == 0) return;

        // Swap asset for USDe
        uint256 minOut = (CURVE_POOL.get_dy(ASSET_INDEX, USDE_INDEX, amount) * (10000 - CURVE_SLIPPAGE)) / 10000;
        uint256 usdeAmount = CURVE_POOL.exchange(ASSET_INDEX, USDE_INDEX, amount, minOut);

        // Stake USDe
        STAKED_USDE.stake(usdeAmount, address(this));
        totalStaked += usdeAmount;
    }

    function _freeFunds(uint256 amount) internal override {
        if (amount == 0) return;

        // Start cooldown if needed
        if (totalStaked >= amount) {
            STAKED_USDE.cooldownAssets(amount);
            (, uint152 pendingAmount) = STAKED_USDE.cooldowns(address(this));
            cooldownAmounts[block.timestamp + 90 days] = uint256(pendingAmount);
            totalStaked -= amount;
        }

        // Process any completed cooldowns
        for (uint256 i = block.timestamp - 90 days; i <= block.timestamp; i += 1 days) {
            uint256 cooldownAmount = cooldownAmounts[i];
            if (cooldownAmount > 0) {
                STAKED_USDE.unstake(address(this));
                delete cooldownAmounts[i];

                // Swap USDe back to asset
                uint256 minOut = (CURVE_POOL.get_dy(USDE_INDEX, ASSET_INDEX, cooldownAmount) * (10000 - CURVE_SLIPPAGE)) / 10000;
                CURVE_POOL.exchange(USDE_INDEX, ASSET_INDEX, cooldownAmount, minOut);
            }
        }
    }

    function _estimateCurrentAssets() internal override returns (uint256) {
        uint256 assetBalance = IERC20(asset).balanceOf(address(this));
        
        // Add staked value
        if (totalStaked > 0) {
            uint256 stakedInAsset = CURVE_POOL.get_dy(USDE_INDEX, ASSET_INDEX, totalStaked);
            assetBalance += stakedInAsset;
        }

        // Add pending unstakes
        for (uint256 i = block.timestamp - 90 days; i <= block.timestamp; i += 1 days) {
            uint256 cooldownAmount = cooldownAmounts[i];
            if (cooldownAmount > 0) {
                uint256 unstakeInAsset = CURVE_POOL.get_dy(USDE_INDEX, ASSET_INDEX, cooldownAmount);
                assetBalance += unstakeInAsset;
            }
        }

        return assetBalance;
    }

    function emergencyWithdraw() external override onlyVault {
        require(isShutdown, "Not shutdown");

        // Unstake any completed cooldowns
        for (uint256 i = block.timestamp - 90 days; i <= block.timestamp; i += 1 days) {
            uint256 cooldownAmount = cooldownAmounts[i];
            if (cooldownAmount > 0 && i + 90 days <= block.timestamp) {
                STAKED_USDE.unstake(address(this));
                delete cooldownAmounts[i];

                // Swap USDe back to asset
                uint256 minOut = (CURVE_POOL.get_dy(USDE_INDEX, ASSET_INDEX, cooldownAmount) * (10000 - CURVE_SLIPPAGE)) / 10000;
                CURVE_POOL.exchange(USDE_INDEX, ASSET_INDEX, cooldownAmount, minOut);
            }
        }

        // Start cooldown for remaining staked amount
        if (totalStaked > 0) {
            STAKED_USDE.cooldownAssets(totalStaked);
            (, uint152 pendingAmount) = STAKED_USDE.cooldowns(address(this));
            cooldownAmounts[block.timestamp + 90 days] = uint256(pendingAmount);
            totalStaked = 0;
        }

        // Transfer any available assets
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance > 0) {
            IERC20(asset).safeTransfer(vault, balance);
        }
    }
}