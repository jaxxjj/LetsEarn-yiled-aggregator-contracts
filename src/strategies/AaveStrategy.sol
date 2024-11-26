// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/TokenizedStrategy.sol";
import "lib/aave-v3-core/contracts/interfaces/IPool.sol";
import "lib/aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";

contract AaveStrategy is TokenizedStrategy {
    using SafeERC20 for IERC20;

    // Constants
    uint256 private constant RAY = 1e27;
    
    // Immutables
    IPool public immutable pool;
    IERC20 public immutable aToken;
    
    // Last recorded normalized income
    uint256 private lastNormalizedIncome;


    constructor(
        address _asset,
        string memory _name,
        address _vault,
        address _pool,
        address _aToken,
        address _feeRecipient
    ) TokenizedStrategy(_asset, _name, "aStrat", _vault, _feeRecipient) {
        require(_pool != address(0), "Invalid pool");
        require(_aToken != address(0), "Invalid aToken");
        
        pool = IPool(_pool);
        aToken = IERC20(_aToken);
        
        // Initial normalized income
        lastNormalizedIncome = pool.getReserveNormalizedIncome(address(asset));
        
        // Approve pool to spend asset
        SafeERC20.forceApprove(IERC20(_asset), _pool, type(uint256).max);
    }

    function _deployFunds(uint256 amount) internal override {
        if (amount > 0) {
            pool.supply(
                address(asset),
                amount,
                address(this),
                0
            );
        }
    }

    function _freeFunds(uint256 amount) internal override {
        if (amount > 0) {
            pool.withdraw(
                address(asset),
                amount,
                address(this)
            );
        }
    }

    function _estimateCurrentAssets() internal override returns (uint256) {
        uint256 currentNormalizedIncome = pool.getReserveNormalizedIncome(address(asset));
        uint256 totalAtoken = aToken.balanceOf(address(this));
        // Calculate current value using normalized income
        uint256 currentValue = (totalAtoken * currentNormalizedIncome) / RAY;
        // Update last normalized income
        lastNormalizedIncome = currentNormalizedIncome;
        
        return currentValue;
    }

    // View functions
    function estimatedTotalAssets() public view returns (uint256) {
        uint256 currentNormalizedIncome = pool.getReserveNormalizedIncome(address(asset));
        uint256 totalAtoken = aToken.balanceOf(address(this));
        return (totalAtoken * currentNormalizedIncome) / RAY;
    }

    function expectedReturn() external view returns (uint256) {
        uint256 currentNormalizedIncome = pool.getReserveNormalizedIncome(address(asset));
        uint256 totalAtoken = aToken.balanceOf(address(this));
        uint256 currentValue = (totalAtoken * currentNormalizedIncome) / RAY;
        return currentValue > totalAssets ? currentValue - totalAssets : 0;
    }

    // Emergency functions
    function emergencyWithdraw() external override onlyVault {
        require(isShutdown, "Not shutdown");
        
        // Withdraw everything from Aave
        uint256 aTokenBalance = aToken.balanceOf(address(this));
        if (aTokenBalance > 0) {
            pool.withdraw(
                address(asset),
                type(uint256).max, // withdraw all
                vault
            );
        }
        
        // Reset accounting
        totalAssets = 0;
    }
}

