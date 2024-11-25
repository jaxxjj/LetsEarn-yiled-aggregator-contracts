// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockStrategy {
    using SafeERC20 for IERC20;
    
    IERC20 public immutable asset;
    uint256 public totalAssets;
    
    constructor(address asset_) {
        asset = IERC20(asset_);
    }
    
    function deposit(uint256 assets) external returns (uint256) {
        asset.safeTransferFrom(msg.sender, address(this), assets);
        totalAssets += assets;
        return assets;
    }
    
    function withdraw(uint256 assets, address receiver) external returns (uint256) {
        require(assets <= totalAssets, "Insufficient assets");
        totalAssets -= assets;
        asset.safeTransfer(receiver, assets);
        return assets;
    }
} 