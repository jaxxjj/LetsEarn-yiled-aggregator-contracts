// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenizedStrategy {
    /// Events
    event Reported(uint256 gain, uint256 loss, uint256 protocolFees, uint256 performanceFees);
    event UpdatePerformanceFee(uint16 newFee);
    event UpdatePerformanceFeeRecipient(address indexed recipient);
    event EmergencyShutdown();

    /// Core Strategy Functions
    function deposit(uint256 amount) external returns (uint256 shares);
    function withdraw(uint256 amount, address receiver) external returns (uint256 assets);
    function report() external returns (uint256 gain, uint256 loss);

    /// View Functions
    function asset() external view returns (address);
    function vault() external view returns (address);
    function totalAssets() external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function performanceFee() external view returns (uint16);
    function performanceFeeRecipient() external view returns (address);
    function isShutdown() external view returns (bool);

    /// Emergency Functions
    function shutdown() external;
    function emergencyWithdraw() external;
}
