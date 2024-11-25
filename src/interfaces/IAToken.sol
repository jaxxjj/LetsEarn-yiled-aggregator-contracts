// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAToken is IERC20 {
    /**
     * @notice Returns the scaled balance of the user.
     * @param user The user whose balance is calculated
     * @return The scaled balance of the user
     */
    function scaledBalanceOf(address user) external view returns (uint256);

    /**
     * @notice Returns the address of the underlying asset
     * @return The address of the underlying asset
     */
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

    /**
     * @notice Returns the address of the lending pool where this aToken is used
     * @return The address of the lending pool
     */
    function POOL() external view returns (address);

    /**
     * @notice Returns the normalized income of the reserve
     * @return The reserve's normalized income
     */
    function getIncentivesController() external view returns (address);

    /**
     * @notice Transfers the underlying asset to `target`.
     * @param target The recipient of the underlying
     * @param amount The amount getting transferred
     * @return The amount transferred
     */
    function transferUnderlyingTo(address target, uint256 amount)
        external
        returns (uint256);
}