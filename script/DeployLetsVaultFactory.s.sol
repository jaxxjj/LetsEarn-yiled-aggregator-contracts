// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {LetsVault} from "../src/core/LetsVault.sol";
import {LetsVaultFactory} from "../src/core/LetsVaultFactory.sol";

contract DeployLetsVaultFactory is Script {
    // Configuration
    uint16 public constant INITIAL_FEE_BPS = 10; // 0.1% initial protocol fee
    
    function run() external {
        // Get deployment private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Vault Implementation
        LetsVault vaultImplementation = new LetsVault();
        console.log("Vault Implementation deployed at:", address(vaultImplementation));

        // 2. Deploy Factory
        LetsVaultFactory factory = new LetsVaultFactory(
            address(vaultImplementation),
            feeRecipient,
            INITIAL_FEE_BPS
        );
        console.log("Factory deployed at:", address(factory));

        // 3. Verify setup
        require(
            factory.VAULT_IMPLEMENTATION() == address(vaultImplementation),
            "Invalid implementation"
        );
        require(
            factory.feeRecipient() == feeRecipient,
            "Invalid fee recipient"
        );
        require(
            factory.protocolFeeBps() == INITIAL_FEE_BPS,
            "Invalid protocol fee"
        );

        vm.stopBroadcast();

        // Log deployment info
        console.log("Deployment completed successfully");
        console.log("-----------------------------------");
        console.log("Factory:", address(factory));
        console.log("Implementation:", address(vaultImplementation));
        console.log("Fee Recipient:", feeRecipient);
        console.log("Initial Fee:", INITIAL_FEE_BPS);
    }
} 