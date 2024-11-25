// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TokenizedStrategy
 * @notice Base contract for creating yield-generating strategies
 */
abstract contract TokenizedStrategy is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Events
    event Reported(
        uint256 gain,
        uint256 loss,
        uint256 protocolFees,
        uint256 performanceFees
    );
    event UpdatePerformanceFee(uint16 newFee);
    event UpdatePerformanceFeeRecipient(address indexed recipient);
    event EmergencyShutdown();

    // Constants
    uint16 public constant MAX_FEE = 5000;         // 50% in basis points
    uint256 public constant MAX_BPS = 10_000;      // 100% in basis points
    
    // Immutables
    IERC20 public immutable asset;                 // Underlying asset
    address public immutable vault;                // Parent vault

    // Strategy state
    bool public isShutdown;                        // Emergency shutdown flag
    uint16 public performanceFee;                  // Performance fee in basis points
    address public performanceFeeRecipient;        // Address to receive performance fees
    uint256 public totalAssets;                    // Total assets managed by strategy
    
    modifier onlyVault() {
        require(msg.sender == vault, "Not vault");
        _;
    }

    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _vault,
        address _feeRecipient
    ) ERC20(_name, _symbol) {
        require(_asset != address(0), "Invalid asset");
        require(_vault != address(0), "Invalid vault");
        require(_feeRecipient != address(0), "Invalid recipient");

        asset = IERC20(_asset);
        vault = _vault;
        performanceFeeRecipient = _feeRecipient;
        performanceFee = 1000;                     // Default 10%
    }

    /**
     * @notice Deposit assets into the strategy
     * @param amount Amount of assets to deposit
     * @return shares Amount of shares minted
     */
    function deposit(uint256 amount) 
        external 
        onlyVault 
        nonReentrant 
        returns (uint256 shares) 
    {
        require(!isShutdown, "Strategy is shutdown");
        require(amount > 0, "Zero amount");

        // Calculate shares to mint
        shares = _convertToShares(amount, Math.Rounding.Floor);
        require(shares > 0, "Zero shares");

        // Transfer assets from vault
        asset.safeTransferFrom(msg.sender, address(this), amount);

        // Deploy funds to yield source
        _deployFunds(amount);

        // Update accounting
        totalAssets += amount;
        _mint(msg.sender, shares);
    }

    /**
     * @notice Withdraw assets from the strategy
     * @param amount Amount of assets to withdraw
     * @param receiver Address to receive assets
     * @return assets Amount of assets withdrawn
     */
    function withdraw(
        uint256 amount,
        address receiver
    ) external onlyVault nonReentrant returns (uint256) {
        require(amount > 0, "Zero amount");
        require(receiver != address(0), "Invalid receiver");

        // Calculate shares to burn
        uint256 shares = _convertToShares(amount, Math.Rounding.Floor);
        require(shares <= balanceOf(msg.sender), "Insufficient shares");

        // Free funds from yield source
        _freeFunds(amount);

        // Update accounting
        totalAssets -= amount;
        _burn(msg.sender, shares);

        // Transfer assets to receiver
        asset.safeTransfer(receiver, amount);

        return amount;
    }

    /**
     * @notice Report strategy performance
     * @return gain Amount of profit
     * @return loss Amount of loss
     */
    function report() external onlyVault nonReentrant returns (uint256 gain, uint256 loss) {
        // Get current assets including yield
        uint256 currentAssets = _estimateCurrentAssets();
        
        // Calculate gain/loss
        if (currentAssets > totalAssets) {
            gain = currentAssets - totalAssets;
            
            // Calculate fees
            uint256 performanceFeeAmount = (gain * performanceFee) / MAX_BPS;
            if (performanceFeeAmount > 0) {
                // Take fees from yield source
                _freeFunds(performanceFeeAmount);
                asset.safeTransfer(performanceFeeRecipient, performanceFeeAmount);
                gain -= performanceFeeAmount;
            }
            
            // Update total assets
            totalAssets = currentAssets - performanceFeeAmount;
            
        } else if (currentAssets < totalAssets) {
            loss = totalAssets - currentAssets;
            totalAssets = currentAssets;
        }

        emit Reported(gain, loss, 0, performanceFee);
        return (gain, loss);
    }

    /**
     * @notice Emergency withdrawal of all funds
     */
    function emergencyWithdraw() external onlyVault nonReentrant {
        require(isShutdown, "Not shutdown");
        
        // Get all funds from yield source
        uint256 totalFunds = _estimateCurrentAssets();
        _freeFunds(totalFunds);
        
        // Transfer everything to vault
        asset.safeTransfer(vault, totalFunds);
        
        // Update accounting
        totalAssets = 0;
    }

    /**
     * @notice Shutdown strategy
     */
    function shutdown() external onlyVault {
        isShutdown = true;
        emit EmergencyShutdown();
    }

    // Internal conversion functions
    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        uint256 supply = totalSupply();
        
        if (supply == 0) {
            return assets;
        }
        
        return assets.mulDiv(supply, totalAssets, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        uint256 supply = totalSupply();
        
        if (supply == 0) {
            return shares;
        }
        
        return shares.mulDiv(totalAssets, supply, rounding);
    }

    // View functions


    function maxDeposit(address) external view returns (uint256) {
        if (isShutdown) return 0;
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
    }

    // Virtual functions to be implemented by specific strategies
    
    /**
     * @notice Deploy funds to yield source
     * @param amount Amount of assets to deploy
     */
    function _deployFunds(uint256 amount) internal virtual;

    /**
     * @notice Free funds from yield source
     * @param amount Amount of assets to free
     */
    function _freeFunds(uint256 amount) internal virtual;

    /**
     * @notice Estimate current total assets including yield
     * @return Total assets estimation
     */
    function _estimateCurrentAssets() internal virtual returns (uint256);
}