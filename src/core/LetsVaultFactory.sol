// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import {ILetsVaultFactory} from "../interfaces/ILetsVaultFactory.sol";
import {ILetsVault} from "../interfaces/ILetsVault.sol";
/**
 * @title Simplified Vault Factory
 * @notice A factory contract for deploying new vaults with minimal functionality
 */
contract LetsVaultFactory is Ownable, ReentrancyGuard, ILetsVaultFactory {
    using Clones for address;

    // Constants
    string public constant API_VERSION = "1.0.0";
    uint16 public constant MAX_FEE_BPS = 5000; // 50% in basis points
    
    // Immutables
    address public immutable VAULT_IMPLEMENTATION;

    // State variables
    bool public isShutdown;
    uint16 public protocolFeeBps;     // Protocol fee in basis points
    address public feeRecipient;      // Address to receive protocol fees
    
    // Tracking deployed vaults
    mapping(address => bool) public isVault;         // Vault => bool
    mapping(address => address) public vaultAsset;   // Vault => underlying asset

    constructor(
        address _vaultImplementation,
        address _feeRecipient,
        uint16 _protocolFeeBps
    ) Ownable(msg.sender) {
        require(_vaultImplementation != address(0), "Invalid implementation");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_protocolFeeBps <= MAX_FEE_BPS, "Fee too high");

        VAULT_IMPLEMENTATION = _vaultImplementation;
        feeRecipient = _feeRecipient;
        protocolFeeBps = _protocolFeeBps;
    }

    /**
     * @notice Deploy a new vault
     * @param asset The underlying asset for the vault
     * @param name The name of the vault token
     * @param symbol The symbol of the vault token
     * @param manager The authorized manager address
     * @return vault The address of the newly deployed vault
     */
    function deployVault(
        address asset,
        string memory name,
        string memory symbol,
        address manager
    ) external nonReentrant returns (address vault) {
        require(!isShutdown, "Factory is shutdown");
        require(asset != address(0), "Invalid asset");
        require(manager != address(0), "Invalid manager");

        // Create deployment salt based on sender, asset, and name
        bytes32 salt = keccak256(
            abi.encode(msg.sender, asset, name, symbol)
        );

        // Deploy vault using minimal proxy pattern
        vault = VAULT_IMPLEMENTATION.cloneDeterministic(salt);
        
        // Initialize vault
        ILetsVault(vault).initialize(
            asset,
            name,
            symbol,
            manager
        );

        // Record vault details
        isVault[vault] = true;
        vaultAsset[vault] = asset;

        emit NewVault(vault, asset);
    }

    /**
     * @notice Get protocol fee configuration
     * @param vault The vault address (unused in this simplified version)
     * @return feeBps Protocol fee in basis points
     * @return recipient Fee recipient address
     */
    function getProtocolFeeConfig(address vault) 
        external 
        view 
        returns (uint16 feeBps, address recipient)
    {
        require(isVault[vault], "Not a valid vault");
        return (protocolFeeBps, feeRecipient);
    }

    /**
     * @notice Update protocol fee
     * @param newFeeBps New fee in basis points
     */
    function setProtocolFee(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "Fee too high");
        uint16 oldFee = protocolFeeBps;
        protocolFeeBps = newFeeBps;
        emit UpdateProtocolFee(oldFee, newFeeBps);
    }

    /**
     * @notice Update fee recipient
     * @param newRecipient New fee recipient address
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit UpdateFeeRecipient(oldRecipient, newRecipient);
    }

    /**
     * @notice Shutdown the factory
     */
    function shutdown() external onlyOwner {
        require(!isShutdown, "Already shutdown");
        isShutdown = true;
        emit FactoryShutdown();
    }

    /**
     * @notice Calculate the deterministic vault address before deployment
     * @param asset The underlying asset
     * @param name The vault name
     * @param symbol The vault symbol
     * @param deployer The deployer address
     */
    function calculateVaultAddress(
        address asset,
        string memory name,
        string memory symbol,
        address deployer
    ) external view returns (address) {
        bytes32 salt = keccak256(
            abi.encode(deployer, asset, name, symbol)
        );
        return VAULT_IMPLEMENTATION.predictDeterministicAddress(salt);
    }
}

