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
    address constant USER = 0x5041ed759Dd4aFc3a72b8192C143F72f4724081A;
    uint24 constant FEE = 3000; // 0.3%
    uint256 constant INITIAL_DEPOSIT = 100_000e6; // 100k USDC
    
    // Contracts
    LetsVaultFactory factory;
    LetsVault vaultImplementation;
    LetsVault vault;
    UniswapV3Strategy strategy;
    IERC20 usdc;
    IERC20 weth;
    INonfungiblePositionManager positionManager;

    struct TestState {
        uint256 userUsdcBalance;
        uint256 userShares;
        uint256 vaultTotalAssets;
        uint256 strategyTotalAssets;
        uint256 tokenId;
        uint256 blockNumber;
        uint256 feeRecipientBalance;
    }

    TestState public state;
    
    function setUp() public {
        // Fork mainnet
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        
        vm.startPrank(USER);

        // Record initial state
        state.blockNumber = block.number;
        
        console.log("Initial setup:");
        console.log("Block:", state.blockNumber);

        // Setup contracts
        usdc = IERC20(USDC);
        weth = IERC20(WETH);
        positionManager = INonfungiblePositionManager(POSITION_MANAGER);
        
        // Deploy contracts
        vaultImplementation = new LetsVault();
        factory = new LetsVaultFactory(
            address(vaultImplementation),
            USER, // fee recipient
            1000 // 10% protocol fee
        );
        
        address vaultAddr = factory.deployVault(
            USDC,
            "USDC Vault",
            "vUSDC",
            USER
        );
        vault = LetsVault(vaultAddr);
        
        // Deploy strategy
        strategy = new UniswapV3Strategy(
            USDC,
            "Uniswap V3 USDC/WETH",
            vaultAddr,
            POSITION_MANAGER,
            UNISWAP_V3_FACTORY,
            USER // fee recipient
        );
        
        // Add strategy to vault
        vault.addStrategy(address(strategy), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);

        vm.stopPrank();
    }

    modifier withDeposit() {
        vm.startPrank(USER);

        // Capture pre-deposit state
        state.userUsdcBalance = usdc.balanceOf(USER);
        state.userShares = vault.balanceOf(USER);
        state.vaultTotalAssets = vault.totalAssets();
        state.strategyTotalAssets = strategy.totalAssets();
        state.blockNumber = block.number;
        state.feeRecipientBalance = usdc.balanceOf(USER); // USER is fee recipient

        // Perform deposit
        vault.deposit(INITIAL_DEPOSIT, USER);

        // Verify deposit
        assertEq(usdc.balanceOf(USER), state.userUsdcBalance - INITIAL_DEPOSIT, "USDC not transferred");
        assertGt(vault.balanceOf(USER), state.userShares, "Shares not minted");
        assertEq(strategy.totalAssets(), INITIAL_DEPOSIT, "Strategy didn't receive funds");

        vm.stopPrank();
        _;
    }
    
    function testInitialState() public {
        assertEq(address(vault.asset()), USDC);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
    }
    
    function testStrategyDeployment() public withDeposit {
        // Process report to deploy funds
        vm.startPrank(USER);
        vault.processReport(address(strategy));
        vm.stopPrank();
        
        // Verify funds deployed
        assertEq(vault.totalIdle(), 0);
        assertGt(strategy.totalAssets(), 0);
        
        // Check Uniswap position
        (uint256 tokenId, , , ) = strategy.currentPosition();
        assertTrue(tokenId > 0, "Position not created");
        state.tokenId = tokenId;
    }
    
    function testMultipleReports() public withDeposit {
        // Initial deployment
        testStrategyDeployment();
        
        uint256[] memory profits = new uint256[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            // Move forward and simulate trading activity
            vm.roll(block.number + 50_400); // ~1 week
            vm.warp(block.timestamp + 7 days);
            
            vm.startPrank(USER);
            uint256 preFeeBalance = usdc.balanceOf(USER);
            vault.processReport(address(strategy));
            profits[i] = usdc.balanceOf(USER) - preFeeBalance;
            
            console.log("\nWeek %s:", i + 1);
            console.log("Performance fee:", profits[i]);
            
            vm.stopPrank();
        }
        
        // Verify profits were collected
        for (uint256 i = 0; i < profits.length; i++) {
            assertGt(profits[i], 0, "No profit in period");
        }
    }
    
    function testEmergencyShutdown() public withDeposit {
        // Setup initial position
        testStrategyDeployment();
        
        uint256 totalAssetsBefore = vault.totalAssets();
        
        vm.startPrank(USER);
        
        // Trigger emergency shutdown
        strategy.shutdown();
        vault.processReport(address(strategy));
        
        vm.stopPrank();
        
        // Verify funds returned to vault
        assertEq(vault.totalIdle(), vault.totalAssets());
        assertEq(strategy.totalAssets(), 0);
        assertGe(vault.totalAssets(), totalAssetsBefore, "Assets lost in shutdown");
        
        // Verify position closed
        (uint256 tokenId, , , ) = strategy.currentPosition();
        assertEq(tokenId, 0, "Position not closed");
    }

    function testWithdraw() public withDeposit {
        // Setup initial position
        testStrategyDeployment();
        
        uint256 withdrawAmount = INITIAL_DEPOSIT / 2;
        uint256 beforeBalance = usdc.balanceOf(USER);
        
        vm.startPrank(USER);
        vault.withdraw(withdrawAmount, USER, USER);
        vm.stopPrank();
        
        uint256 afterBalance = usdc.balanceOf(USER);
        assertEq(afterBalance - beforeBalance, withdrawAmount, "Incorrect withdrawal amount");
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT - withdrawAmount, "Incorrect total assets");
    }
} 