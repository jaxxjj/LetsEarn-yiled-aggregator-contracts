// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {UniswapV3Strategy} from "../../src/strategies/UniswapV3Strategy.sol";
import {LetsVault} from "../../src/core/LetsVault.sol";
import {LetsVaultFactory} from "../../src/core/LetsVaultFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

contract UniswapV3ForkTest is Test {
    // Constants
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    uint24 constant FEE = 3000; // 0.3%
    
    // Contracts
    UniswapV3Strategy public strategy;
    LetsVault public vault;
    LetsVaultFactory public factory;
    IERC20 public usdc;
    IERC20 public weth;
    INonfungiblePositionManager public positionManager;
    
    // Test addresses
    address public whale = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503; // Binance wallet
    address public user = address(0x1);
    
    function setUp() public {
        // Fork mainnet
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        
        // Setup contracts
        usdc = IERC20(USDC);
        weth = IERC20(WETH);
        positionManager = INonfungiblePositionManager(POSITION_MANAGER);
        
        // Deploy factory and vault
        factory = new LetsVaultFactory();
        vault = LetsVault(factory.deployVault(USDC));
        
        // Deploy strategy
        strategy = new UniswapV3Strategy(
            USDC,
            "Uniswap V3 USDC/WETH",
            address(vault),
            POSITION_MANAGER,
            UNISWAP_V3_FACTORY,
            address(this)
        );
        
        // Add strategy to vault
        vault.addStrategy(address(strategy));
        
        // Fund test accounts
        vm.startPrank(whale);
        usdc.transfer(user, 1_000_000e6); // 1M USDC
        vm.stopPrank();
    }
    
    function testInitialState() public {
        assertEq(address(vault.asset()), USDC);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
    }
    
    function testDeposit() public {
        uint256 depositAmount = 100_000e6; // 100k USDC
        
        vm.startPrank(user);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();
        
        assertEq(vault.totalAssets(), depositAmount);
        assertEq(vault.totalIdle(), depositAmount);
        assertEq(vault.balanceOf(user), depositAmount);
    }
    
    function testStrategyDeployment() public {
        uint256 depositAmount = 100_000e6; // 100k USDC
        
        // Deposit funds
        vm.startPrank(user);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();
        
        // Process report to deploy funds
        vault.processReport(address(strategy));
        
        // Verify funds deployed
        assertEq(vault.totalIdle(), 0);
        assertGt(strategy.totalAssets(), 0);
        
        // Check Uniswap position
        (uint256 tokenId,,,,,,,,,,) = strategy.currentPosition();
        assertTrue(tokenId > 0, "Position not created");
    }
    
    function testHarvest() public {
        // Setup initial position
        testStrategyDeployment();
        
        // Simulate time passing and trading activity
        vm.warp(block.timestamp + 7 days);
        
        // Process report to collect fees
        uint256 beforeAssets = vault.totalAssets();
        vault.processReport(address(strategy));
        uint256 afterAssets = vault.totalAssets();
        
        assertTrue(afterAssets >= beforeAssets, "No fees collected");
    }
    
    function testWithdraw() public {
        // Setup initial position
        testStrategyDeployment();
        
        uint256 withdrawAmount = 50_000e6; // 50k USDC
        uint256 beforeBalance = usdc.balanceOf(user);
        
        vm.startPrank(user);
        vault.withdraw(withdrawAmount);
        vm.stopPrank();
        
        uint256 afterBalance = usdc.balanceOf(user);
        assertEq(afterBalance - beforeBalance, withdrawAmount);
    }
    
    function testEmergencyShutdown() public {
        // Setup initial position
        testStrategyDeployment();
        
        // Trigger emergency shutdown
        strategy.setShutdown(true);
        vault.processReport(address(strategy));
        
        // Verify funds returned to vault
        assertEq(vault.totalIdle(), vault.totalAssets());
        assertEq(strategy.totalAssets(), 0);
        
        // Verify position closed
        (uint256 tokenId,,,,,,,,,,) = strategy.currentPosition();
        assertEq(tokenId, 0, "Position not closed");
    }
} 