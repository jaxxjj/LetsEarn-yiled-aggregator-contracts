// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/core/LetsVault.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockStrategy.sol";

contract LetsVaultTest is Test {
    LetsVault public vault;
    MockERC20 public underlying;
    MockStrategy public strategy;
    
    address public factory;
    address public manager;
    address public user;
    
    uint256 constant INITIAL_BALANCE = 1000e18;
    
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event StrategyReported(address indexed strategy, uint256 gain, uint256 loss, uint256 currentDebt, uint256 protocolFee);
    event DebtUpdated(address indexed strategy, uint256 currentDebt, uint256 targetDebt);
    event UpdateManager(address indexed newManager);
    
    function setUp() public {
        factory = makeAddr("factory");
        manager = makeAddr("manager");
        user = makeAddr("user");
        
        vm.startPrank(factory);
        
        // Deploy contracts
        underlying = new MockERC20("Test Token", "TEST", 18);
        vault = new LetsVault();
        strategy = new MockStrategy(address(underlying));
        
        // Initialize vault
        vault.initialize(
            address(underlying),
            "Test Vault",
            "vTEST",
            manager
        );
        
        vm.stopPrank();
        
        // Setup initial balances
        underlying.mint(user, INITIAL_BALANCE);
        
        vm.prank(user);
        underlying.approve(address(vault), type(uint256).max);
    }
    
    // Initialization Tests
    
    function test_Initialize() public {
        assertEq(vault.name(), "Test Vault");
        assertEq(vault.symbol(), "vTEST");
        assertEq(address(vault.underlying()), address(underlying));
        assertEq(vault.manager(), manager);
        assertEq(vault.factory(), factory);
    }
    
    function testFail_InitializeTwice() public {
        vm.prank(factory);
        vault.initialize(address(underlying), "Test2", "TEST2", manager);
    }
    
    function testFail_InitializeZeroAsset() public {
        LetsVault newVault = new LetsVault();
        vm.prank(factory);
        newVault.initialize(address(0), "Test", "TEST", manager);
    }
    
    // Deposit Tests
    
    function test_Deposit() public {
        uint256 depositAmount = 100e18;
        
        vm.startPrank(user);
        
        vm.expectEmit(true, true, false, true);
        emit Deposit(user, user, depositAmount, depositAmount);
        
        uint256 shares = vault.deposit(depositAmount, user);
        
        assertEq(shares, depositAmount);
        assertEq(vault.totalAssets(), depositAmount);
        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.totalIdle(), depositAmount);
        
        vm.stopPrank();
    }
    
    function testFail_DepositZero() public {
        vm.prank(user);
        vault.deposit(0, user);
    }
    
    function testFail_DepositToZeroAddress() public {
        vm.prank(user);
        vault.deposit(100e18, address(0));
    }
    
    // Withdraw Tests
    
    function test_Withdraw() public {
        uint256 depositAmount = 100e18;
        
        // Setup - deposit first
        vm.prank(user);
        vault.deposit(depositAmount, user);
        
        vm.startPrank(user);
        
        vm.expectEmit(true, true, true, true);
        emit Withdraw(user, user, user, depositAmount, depositAmount);
        
        uint256 shares = vault.withdraw(depositAmount, user, user);
        
        assertEq(shares, depositAmount);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.balanceOf(user), 0);
        assertEq(underlying.balanceOf(user), INITIAL_BALANCE);
        
        vm.stopPrank();
    }
    
    // Strategy Management Tests
    
    function test_AddStrategy() public {
        vm.startPrank(manager);
        
        uint256 maxDebt = 1000e18;
        
        vm.expectEmit(true, false, false, false);
        emit StrategyAdded(address(strategy));
        
        vault.addStrategy(address(strategy), maxDebt);
        
        (uint256 activation, uint256 lastReport, uint256 currentDebt, uint256 maxDebtActual) = 
            vault.strategies(address(strategy));
            
        assertGt(activation, 0);
        assertEq(lastReport, activation);
        assertEq(currentDebt, 0);
        assertEq(maxDebtActual, maxDebt);
        
        vm.stopPrank();
    }
    
    function testFail_AddStrategyNotManager() public {
        vm.prank(user);
        vault.addStrategy(address(strategy), 1000e18);
    }
    
    function test_RemoveStrategy() public {
        // Setup - add strategy first
        vm.prank(manager);
        vault.addStrategy(address(strategy), 1000e18);
        
        vm.startPrank(manager);
        
        vm.expectEmit(true, false, false, false);
        emit StrategyRemoved(address(strategy));
        
        vault.removeStrategy(address(strategy));
        
        (uint256 activation,,, uint256 maxDebt) = vault.strategies(address(strategy));
        assertEq(activation, 0);
        assertEq(maxDebt, 0);
        
        vm.stopPrank();
    }
    
    function test_UpdateDebt() public {
        // Setup
        vm.prank(manager);
        vault.addStrategy(address(strategy), 1000e18);
        
        vm.prank(user);
        vault.deposit(500e18, user);
        
        uint256 targetDebt = 200e18;
        
        vm.startPrank(manager);
        
        vm.expectEmit(true, false, false, true);
        emit DebtUpdated(address(strategy), 500e18, targetDebt);
        
        vault.updateDebt(address(strategy), targetDebt);
        
        (,,uint256 currentDebt,) = vault.strategies(address(strategy));
        assertEq(currentDebt, targetDebt);
        assertEq(vault.totalDebt(), targetDebt);
        assertEq(vault.totalIdle(), 300e18);
        
        vm.stopPrank();
    }
    
    // Emergency Functions Tests
    
    function test_Pause() public {
        vm.prank(manager);
        vault.pause();
        assertTrue(vault.paused());
        
        vm.expectRevert();
        vm.prank(user);
        vault.deposit(100e18, user);
    }
    
    function test_Unpause() public {
        vm.prank(manager);
        vault.pause();
        
        vm.prank(manager);
        vault.unpause();
        assertFalse(vault.paused());
        
        // Should be able to deposit again
        vm.prank(user);
        vault.deposit(100e18, user);
    }
    
    function test_SetManager() public {
        address newManager = makeAddr("newManager");
        
        vm.startPrank(manager);
        
        vm.expectEmit(true, false, false, false);
        emit UpdateManager(newManager);
        
        vault.setManager(newManager);
        assertEq(vault.manager(), newManager);
        
        vm.stopPrank();
    }
    
    // Redeem Tests
    function test_Redeem() public {
        uint256 depositAmount = 100e18;
        
        // Setup - deposit first
        vm.prank(user);
        vault.deposit(depositAmount, user);
        
        vm.startPrank(user);
        
        vm.expectEmit(true, true, true, true);
        emit Withdraw(user, user, user, depositAmount, depositAmount);
        
        uint256 assets = vault.redeem(depositAmount, user, user);
        
        assertEq(assets, depositAmount);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.balanceOf(user), 0);
        assertEq(underlying.balanceOf(user), INITIAL_BALANCE);
        
        vm.stopPrank();
    }

    
    // Strategy Management Tests
    function test_MultipleStrategies() public {
        MockStrategy strategy2 = new MockStrategy(address(underlying));
        
        // Manager actions - add strategies
        vm.startPrank(manager);
        vault.addStrategy(address(strategy), 500e18);
        vault.addStrategy(address(strategy2), 500e18);
        vm.stopPrank();
        
        // User action - deposit
        vm.startPrank(user);
        vault.deposit(1000e18, user);
        vm.stopPrank();
        
        // Manager actions - update debts
        vm.startPrank(manager);
        vault.updateDebt(address(strategy), 300e18);
        vault.updateDebt(address(strategy2), 400e18);
        
        assertEq(vault.totalDebt(), 700e18);
        assertEq(vault.totalIdle(), 300e18);
        
        // Verify strategy balances
        (,,uint256 debt1,) = vault.strategies(address(strategy));
        (,,uint256 debt2,) = vault.strategies(address(strategy2));
        assertEq(debt1, 300e18);
        assertEq(debt2, 400e18);
        vm.stopPrank();
    }
    
    function test_MaxDebtLimit() public {
        uint256 maxDebt = 500e18;
        
        // Manager adds strategy
        vm.startPrank(manager);
        vault.addStrategy(address(strategy), maxDebt);
        vm.stopPrank();
        
        // User deposits
        vm.startPrank(user);
        vault.deposit(1000e18, user);
        vm.stopPrank();
        
        // Manager updates debt
        vm.startPrank(manager);
        // Try to exceed max debt
        vm.expectRevert("Exceeds max debt");
        vault.updateDebt(address(strategy), maxDebt + 1);
        
        // Should work within limit
        vault.updateDebt(address(strategy), maxDebt);
        (,,uint256 currentDebt,) = vault.strategies(address(strategy));
        assertEq(currentDebt, maxDebt);
        vm.stopPrank();
    }
    
    
    function test_ManagerOnlyFunctions() public {
        vm.prank(user);
        vm.expectRevert("Not manager");
        vault.addStrategy(address(strategy), 1000e18);
        
        vm.prank(user);
        vm.expectRevert("Not manager");
        vault.pause();
    }
    
    // View Function Tests
    function test_TotalAssets() public {
        vm.prank(user);
        vault.deposit(1000e18, user);
        
        vm.startPrank(manager);
        vault.addStrategy(address(strategy), 1000e18);
        vault.updateDebt(address(strategy), 600e18);
        
        assertEq(vault.totalAssets(), 1000e18);
        assertEq(vault.totalDebt(), 600e18);
        assertEq(vault.totalIdle(), 400e18);
    }
    
    function test_MaxDepositPaused() public {
        vm.prank(manager);
        vault.pause();
        assertEq(vault.maxDeposit(user), 0);
    }
    
    function test_MaxWithdraw() public {
        uint256 depositAmount = 100e18;
        
        vm.prank(user);
        vault.deposit(depositAmount, user);
        
        assertEq(vault.maxWithdraw(user), depositAmount);
    }
    

} 
