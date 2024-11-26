// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/ITokenizedStrategy.sol";
import "lib/aave-v3-core/contracts/interfaces/IPool.sol";

contract AaveStrategy is ITokenizedStrategy {
    using SafeERC20 for IERC20;

    // Constants
    uint16 public constant MAX_BPS = 10_000; // 100%

    // Storage
    IERC20 public immutable asset_;
    IERC20 public immutable aToken;
    IPool public immutable pool;
    address public immutable vault_;
    string public name;
    
    // Fee configuration
    uint16 public performanceFee_;
    address public performanceFeeRecipient_;
    
    // Emergency shutdown
    bool public isShutdown_;

    constructor(
        address _asset,
        string memory _name,
        address _vault,
        address _pool,
        address _aToken
    ) {
        require(_asset != address(0), "Invalid asset");
        require(_vault != address(0), "Invalid vault");
        require(_pool != address(0), "Invalid pool");
        require(_aToken != address(0), "Invalid aToken");

        asset_ = IERC20(_asset);
        aToken = IERC20(_aToken);
        pool = IPool(_pool);
        vault_ = _vault;
        name = _name;
        
        // Initialize fee configuration
        performanceFee_ = 1000; // 10% default
        performanceFeeRecipient_ = msg.sender;

        // Use forceApprove instead of safeApprove for USDT
        SafeERC20.forceApprove(asset_, _pool, type(uint256).max);
    }

    // Core functions
    function deposit(uint256 amount) external returns (uint256) {
        require(msg.sender == vault_, "Not vault");
        require(!isShutdown_, "Strategy is shutdown");
        
        if (amount > 0) {
            // Pull USDC from vault first
            asset_.safeTransferFrom(vault_, address(this), amount);
            
            // Supply to Aave - use msg.sender (strategy) as onBehalfOf
            pool.supply(
                address(asset_),
                amount,
                address(this),  // strategy receives aTokens
                0  // referral code
            );
        }
        
        return amount;
    }

    function withdraw(uint256 amount, address receiver) external returns (uint256) {
        require(msg.sender == vault_, "Not vault");
        require(receiver != address(0), "Invalid receiver");

        if (amount > 0) {
            // Withdraw USDC from Aave directly to receiver (vault)
            pool.withdraw(
                address(asset_),
                amount,
                receiver  // send USDC directly to vault
            );
        }

        return amount;
    }

    function report() external returns (uint256 gain, uint256 loss) {
        require(msg.sender == vault_, "Not vault");
        
        uint256 totalAssetsBefore = totalAssets();
        uint256 totalSupply = aToken.balanceOf(address(this));
        
        if (totalSupply > totalAssetsBefore) {
            gain = totalSupply - totalAssetsBefore;
            
            // Calculate and transfer performance fee
            uint256 performanceFeeAmount = (gain * performanceFee_) / MAX_BPS;
            if (performanceFeeAmount > 0) {
                pool.withdraw(address(asset_), performanceFeeAmount, performanceFeeRecipient_);
                gain -= performanceFeeAmount;
            }
            
            emit Reported(gain, 0, 0, performanceFeeAmount);
        } else if (totalSupply < totalAssetsBefore) {
            loss = totalAssetsBefore - totalSupply;
            emit Reported(0, loss, 0, 0);
        }
        
        return (gain, loss);
    }

    // View functions
    function asset() external view returns (address) {
        return address(asset_);
    }

    function vault() external view returns (address) {
        return vault_;
    }

    function totalAssets() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function maxDeposit(address) external view returns (uint256) {
        if (isShutdown_) return 0;
        return type(uint256).max;
    }

    function maxWithdraw(address) external view returns (uint256) {
        return totalAssets();
    }

    function performanceFee() external view returns (uint16) {
        return performanceFee_;
    }

    function performanceFeeRecipient() external view returns (address) {
        return performanceFeeRecipient_;
    }

    function isShutdown() external view returns (bool) {
        return isShutdown_;
    }

    // Admin functions
    function shutdown() external {
        require(msg.sender == vault_, "Not vault");
        isShutdown_ = true;
        emit EmergencyShutdown();
    }

    function emergencyWithdraw() external {
        require(isShutdown_, "Not shutdown");
        require(msg.sender == vault_, "Not vault");
        
        uint256 totalBalance = aToken.balanceOf(address(this));
        if (totalBalance > 0) {
            pool.withdraw(address(asset_), totalBalance, vault_);
        }
    }
}

