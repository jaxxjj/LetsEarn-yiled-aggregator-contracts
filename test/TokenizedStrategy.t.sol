// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/core/TokenizedStrategy.sol";
import "../src/mocks/MockERC20.sol";

// Mock implementation of TokenizedStrategy for testing
contract MockStrategy is TokenizedStrategy {
    uint256 public currentAssets; // Track current assets for testing
    
    constructor(
        address _asset,
        address _vault,
        address _feeRecipient
    ) TokenizedStrategy(
        _asset,
        "Mock Strategy",
        "mSTRAT",
        _vault,
        _feeRecipient
    ) {
        currentAssets = 0;
    }
    
    // Set current assets for testing (to simulate gains/losses)
    function setCurrentAssets(uint256 _assets) external {
        currentAssets = _assets;
    }
    
    function _deployFunds(uint256 amount) internal override {
        currentAssets += amount;
    }
    
    function _freeFunds(uint256 amount) internal override {
        currentAssets -= amount;
    }
    
    function _estimateCurrentAssets() internal override returns (uint256) {
        return currentAssets;
    }
}

contract TokenizedStrategyTest is Test {
    MockStrategy public strategy;
    MockERC20 public asset;
    address public vault;
    address public feeRecipient;
    address public user;
    
    uint256 constant INITIAL_BALANCE = 1000e18;
    
    event Reported(uint256 gain, uint256 loss, uint256 protocolFees, uint256 performanceFees);
    event UpdatePerformanceFee(uint16 newFee);
    event UpdatePerformanceFeeRecipient(address indexed recipient);
    event EmergencyShutdown();
    
    function setUp() public {
        vault = makeAddr("vault");
        feeRecipient = makeAddr("feeRecipient");
        user = makeAddr("user");
        
        // Deploy contracts
        asset = new MockERC20("Test Token", "TEST", 18);
        strategy = new MockStrategy(
            address(asset),
            vault,
            feeRecipient
        );
        
        // Setup initial balances
        asset.mint(vault, INITIAL_BALANCE);
        
        vm.prank(vault);
        asset.approve(address(strategy), type(uint256).max);
    }
    
    // Initialization Tests
    
    function test_Initialize() public {
        assertEq(address(strategy.asset()), address(asset));
        assertEq(strategy.vault(), vault);
        assertEq(strategy.performanceFeeRecipient(), feeRecipient);
        assertEq(strategy.performanceFee(), 1000); // 10%
        assertEq(strategy.isShutdown(), false);
    }
    
    function testFail_InitializeZeroAsset() public {
        new MockStrategy(
            address(0),
            vault,
            feeRecipient
        );
    }
    
    // Deposit Tests
    
    function test_FirstDeposit() public {
        uint256 amount = 100e18;
        
        vm.startPrank(vault);
        uint256 shares = strategy.deposit(amount);
        vm.stopPrank();
        
        assertEq(shares, amount); // 1:1 for first deposit
        assertEq(strategy.totalAssets(), amount);
        assertEq(strategy.totalSupply(), amount);
        assertEq(strategy.balanceOf(vault), amount);
    }
    
    function test_SubsequentDeposit() public {
        // First deposit
        vm.startPrank(vault);
        strategy.deposit(100e18);
        
        // Simulate profit by doubling current assets
        strategy.setCurrentAssets(200e18);
        strategy.report(); // Report the profit (10% fee taken)
        
        // After fee:
        // totalAssets = 190e18 (200e18 - 10e18 fee)
        // totalSupply = 100e18
        // New deposit = 100e18
        // Expected shares = 100e18 * 100e18 / 190e18 ≈ 52.63e18
        
        uint256 shares = strategy.deposit(100e18);
        vm.stopPrank();
        
        assertEq(shares, 52631578947368421052); // ~52.63e18 shares
        assertEq(strategy.totalAssets(), 290e18); // 190e18 + 100e18 new deposit
    }
    
    function testFail_DepositZero() public {
        vm.prank(vault);
        strategy.deposit(0);
    }
    
    function testFail_DepositNotVault() public {
        vm.prank(user);
        strategy.deposit(100e18);
    }
    
    // Withdraw Tests
    
    function test_Withdraw() public {
        uint256 depositAmount = 100e18;
        
        // Setup - deposit first
        vm.startPrank(vault);
        strategy.deposit(depositAmount);
        
        uint256 withdrawnAmount = strategy.withdraw(depositAmount, vault);
        vm.stopPrank();
        
        assertEq(withdrawnAmount, depositAmount);
        assertEq(strategy.totalAssets(), 0);
        assertEq(strategy.totalSupply(), 0);
        assertEq(strategy.balanceOf(vault), 0);
    }
    
    function testFail_WithdrawZero() public {
        vm.prank(vault);
        strategy.withdraw(0, vault);
    }
    
    function testFail_WithdrawNotVault() public {
        vm.prank(user);
        strategy.withdraw(100e18, user);
    }
    
    // Performance Tests
    
    function test_Report() public {
        // Setup - deposit and simulate profit
        vm.startPrank(vault);
        strategy.deposit(100e18);
        
        strategy.setCurrentAssets(150e18); // 50e18 profit
        
        vm.expectEmit(false, false, false, true);
        emit Reported(45e18, 0, 0, 1000); // 45e18 gain after 10% fee
        
        (uint256 gain, uint256 loss) = strategy.report();
        vm.stopPrank();
        
        assertEq(gain, 45e18); // 50e18 - 5e18 fee
        assertEq(loss, 0);
        assertEq(asset.balanceOf(feeRecipient), 5e18); // 10% fee
        assertEq(strategy.totalAssets(), 145e18);
    }
    
    function test_ReportLoss() public {
        // Setup - deposit
        vm.startPrank(vault);
        strategy.deposit(100e18);
        
        // Simulate loss by setting current assets lower than totalAssets
        strategy.setCurrentAssets(80e18); // 20e18 loss
        
        vm.expectEmit(false, false, false, true);
        emit Reported(0, 20e18, 0, 1000);
        
        (uint256 gain, uint256 loss) = strategy.report();
        vm.stopPrank();
        
        assertEq(gain, 0);
        assertEq(loss, 20e18);
        assertEq(strategy.totalAssets(), 80e18);
    }
    
    function test_ReportGain() public {
        // Setup - deposit
        vm.startPrank(vault);
        strategy.deposit(100e18);
        
        // Simulate gain by setting current assets higher than totalAssets
        strategy.setCurrentAssets(150e18); // 50e18 gain
        
        vm.expectEmit(false, false, false, true);
        emit Reported(45e18, 0, 0, 1000); // 45e18 after 10% fee
        
        (uint256 gain, uint256 loss) = strategy.report();
        vm.stopPrank();
        
        assertEq(gain, 45e18); // 50e18 - 5e18 fee
        assertEq(loss, 0);
        assertEq(asset.balanceOf(feeRecipient), 5e18); // 10% fee
        assertEq(strategy.totalAssets(), 145e18);
    }
    
    // Emergency Tests
    
    function test_EmergencyShutdown() public {
        vm.prank(vault);
        strategy.shutdown();
        
        assertTrue(strategy.isShutdown());
        
        vm.prank(vault);
        vm.expectRevert("Strategy is shutdown");
        strategy.deposit(100e18);
    }
    
    function test_EmergencyWithdraw() public {
        // Reset vault balance to exactly what we need
        deal(address(asset), vault, 100e18); 
        
        // Setup - deposit and simulate profit
        vm.startPrank(vault);
        strategy.deposit(100e18);
        
        // Simulate profit by minting additional tokens to strategy
        asset.mint(address(strategy), 50e18);
        strategy.setCurrentAssets(150e18);
        
        strategy.shutdown();
        strategy.emergencyWithdraw();
        vm.stopPrank();
        
        assertEq(asset.balanceOf(vault), 150e18);
        assertEq(strategy.totalAssets(), 0);
    }
    
    function testFail_EmergencyWithdrawNotShutdown() public {
        vm.prank(vault);
        strategy.emergencyWithdraw();
    }
    
    // View Function Tests
    
    function test_MaxDeposit() public {
        assertEq(strategy.maxDeposit(address(0)), type(uint256).max);
        
        vm.prank(vault);
        strategy.shutdown();
        
        assertEq(strategy.maxDeposit(address(0)), 0);
    }
    
    function test_MaxWithdraw() public {
        vm.startPrank(vault);
        strategy.deposit(100e18);
        
        assertEq(strategy.maxWithdraw(vault), 100e18);
        
        strategy.withdraw(50e18, vault);
        assertEq(strategy.maxWithdraw(vault), 50e18);
        vm.stopPrank();
    }
} 