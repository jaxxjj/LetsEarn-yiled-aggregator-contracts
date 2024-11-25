// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVault
 * @notice Core vault interface for asset management
 */
interface ILetsVault {
    /// Events
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event StrategyReported(address indexed strategy, uint256 gain, uint256 loss, uint256 totalDebt, uint256 protocolFees);
    event DebtUpdated(address indexed strategy, uint256 currentDebt, uint256 newDebt);
    event UpdateManager(address indexed newManager);
    /// Initialization
    function initialize(
        address asset_,
        string memory name_,
        string memory symbol_,
        address manager_
    ) external;

    /// Core ERC4626 Functions
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// Strategy Management
    function addStrategy(address strategy, uint256 maxDebt) external;
    function removeStrategy(address strategy) external;
    function updateDebt(address strategy, uint256 targetDebt) external;
    function processReport(address strategy) external returns (uint256 gain, uint256 loss);

    /// View Functions
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalDebt() external view returns (uint256);
    function totalIdle() external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function getActiveStrategies() external view returns (address[] memory);
    function strategies(address strategy) external view returns (
        uint256 activation,
        uint256 lastReport,
        uint256 currentDebt,
        uint256 maxDebt
    );

    /// Management Functions 
    function setManager(address newManager) external;
    function pause() external;
    function unpause() external;
}