// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILetsVaultFactory {
    /// Events
    event NewVault(address indexed vault, address indexed asset);
    event UpdateProtocolFee(uint16 oldFee, uint16 newFee);
    event UpdateFeeRecipient(address indexed oldRecipient, address indexed newRecipient);
    event FactoryShutdown();

    /// Vault Deployment
    function deployVault(address asset, string memory name, string memory symbol, address manager)
        external
        returns (address vault);

    /// Fee Management
    function getProtocolFeeConfig(address vault) external view returns (uint16 feeBps, address recipient);
    function setProtocolFee(uint16 newFeeBps) external;
    function setFeeRecipient(address newRecipient) external;

    /// Factory Management
    function shutdown() external;
    function isShutdown() external view returns (bool);
    function VAULT_IMPLEMENTATION() external view returns (address);
    function calculateVaultAddress(address asset, string memory name, string memory symbol, address deployer)
        external
        view
        returns (address);
}
