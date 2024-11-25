// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {LetsVaultFactory} from "../src/core/LetsVaultFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployTestVault is Script {
    function run() external {
        // Load configuration
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address assetAddress = vm.envAddress("ASSET_ADDRESS");
        address vaultManager = vm.envAddress("VAULT_MANAGER");
        
        // Configuration for vault
        string memory name = "Test Vault";
        string memory symbol = "tVAULT";

        vm.startBroadcast(deployerPrivateKey);

        // Deploy vault through factory
        LetsVaultFactory factory = LetsVaultFactory(factoryAddress);
        address vault = factory.deployVault(
            assetAddress,
            name,
            symbol,
            vaultManager
        );

        vm.stopBroadcast();

        // Log deployment
        console.log("Test Vault deployed successfully");
        console.log("-----------------------------------");
        console.log("Vault Address:", vault);
        console.log("Underlying Asset:", assetAddress);
        console.log("Manager:", vaultManager);
        console.log("Name:", name);
        console.log("Symbol:", symbol);
    }
} 