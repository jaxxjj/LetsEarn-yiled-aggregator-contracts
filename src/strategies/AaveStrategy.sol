// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/TokenizedStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IAavePool.sol";
import "../interfaces/IAToken.sol";

contract AaveStrategy is TokenizedStrategy {
    using SafeERC20 for IERC20;

    // Aave contracts
    IAavePool public immutable aavePool;
    IAToken public immutable aToken;
    
    // Minimum health factor to maintain (1.1)
    uint256 constant MIN_HEALTH_FACTOR = 110_000;

    constructor(
        address _asset,
        string memory _name,
        address _vault,
        address _aavePool,
        address _aToken
    ) TokenizedStrategy(
        _asset,
        _name,
        "aSTRAT",
        _vault,
        msg.sender  // management
    ) {
        aavePool = IAavePool(_aavePool);
        aToken = IAToken(_aToken);
        
        // Approve pool to spend asset
        IERC20(_asset).approve(_aavePool, type(uint256).max);
    }

    function _deployFunds(uint256 amount) internal override {
        // Supply assets to Aave
        aavePool.supply(address(asset), amount, address(this), 0);
    }

    function _freeFunds(uint256 amount) internal override {
        // Withdraw from Aave
        aavePool.withdraw(address(asset), amount, address(this));
    }

    function _estimateCurrentAssets() internal view override returns (uint256) {
        // Get aToken balance which represents our position
        return aToken.balanceOf(address(this));
    }

    // Emergency function to withdraw everything
    function emergencyWithdraw() external override onlyVault nonReentrant {
        uint256 aTokenBalance = aToken.balanceOf(address(this));
        if(aTokenBalance > 0) {
            aavePool.withdraw(address(asset), aTokenBalance, address(this));
        }
        
        // Update accounting
        totalAssets = 0;
    }

    // Check health factor
    function checkHealth() public view returns (uint256) {
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        return healthFactor;
    }

    // Rebalance if health factor is too low
    function rebalance() external {
        require(checkHealth() < MIN_HEALTH_FACTOR, "Health factor OK");
        
        // Withdraw some collateral to improve health factor
        uint256 balance = aToken.balanceOf(address(this));
        uint256 withdrawAmount = balance / 10; // Withdraw 10%
        _freeFunds(withdrawAmount);
    }
} 