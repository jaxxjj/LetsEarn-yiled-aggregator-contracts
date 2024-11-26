// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/strategies/AaveStrategy.sol";
import "../../src/core/LetsVault.sol";
import "../../src/core/LetsVaultFactory.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AaveStrategyTest is Test {
    // Mainnet addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address constant USER = 0x5041ed759Dd4aFc3a72b8192C143F72f4724081A;
    
    // Contracts
    LetsVaultFactory factory;
    LetsVault vaultImplementation;
    LetsVault vault;
    AaveStrategy strategy;
    IERC20 usdc = IERC20(USDC);

    function setUp() public {
        // Setup test account
        vm.startPrank(USER);
        console.log("Forked at block:", block.number);
        IPool pool = IPool(AAVE_POOL);
        DataTypes.ReserveData memory data = pool.getReserveData(USDC);
        
        console.log("\nUSDC Reserve Status Check:");
        console.log("liquidityIndex:", data.liquidityIndex);
        console.log("currentLiquidityRate:", data.currentLiquidityRate);
        console.log("aTokenAddress:", data.aTokenAddress);
        
        // 检查用户 USDC 余额
        uint256 userBalance = IERC20(USDC).balanceOf(USER);
        console.log("\nUser USDC balance:", userBalance);
        // Deploy factory and implementation
        vaultImplementation = new LetsVault();
        factory = new LetsVaultFactory(
            address(vaultImplementation),
            USER, // fee recipient
            1000  // 10% protocol fee
        );
        console.log("Factory deployed at", address(factory));
        // Deploy vault
        address vaultAddr = factory.deployVault(
            USDC,
            "USDC Vault",
            "vUSDC",
            USER
        );
        console.log("Vault deployed at", vaultAddr);
        vault = LetsVault(vaultAddr);
        
        // Deploy strategy
        strategy = new AaveStrategy(
            USDC,
            "Aave USDC Strategy",
            vaultAddr,
            AAVE_POOL,
            AUSDC
        );
        console.log("Strategy deployed at", address(strategy));
        // Add strategy to vault
        vault.addStrategy(address(strategy), type(uint256).max);
        
       
        usdc.approve(address(vault), type(uint256).max);
        
        vm.stopPrank();
    }

    function testDeposit() public {
        uint256 depositAmount = 100000e6; // 100k USDC
        
        vm.startPrank(USER);
        
        // Get initial balances
        uint256 userUsdcBefore = usdc.balanceOf(USER);
        uint256 vaultSharesBefore = vault.balanceOf(USER);
        
        // Perform deposit
        vault.deposit(depositAmount, USER);
        
        // Get final balances
        uint256 userUsdcAfter = usdc.balanceOf(USER);
        uint256 vaultSharesAfter = vault.balanceOf(USER);
        uint256 strategyBalance = strategy.totalAssets();
        
        // Verify balances
        assertEq(userUsdcBefore - userUsdcAfter, depositAmount, "Incorrect USDC transfer");
        assertTrue(vaultSharesAfter > vaultSharesBefore, "No shares minted");
        assertEq(strategyBalance, depositAmount, "Funds not in strategy");
        
        // Verify aToken balance
        uint256 aTokenBalance = IERC20(AUSDC).balanceOf(address(strategy));
        assertEq(aTokenBalance, depositAmount, "Incorrect aToken balance");
        
        vm.stopPrank();
    }
}