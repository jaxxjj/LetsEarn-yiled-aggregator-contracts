// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/strategies/AaveStrategy.sol";
import "../../src/core/LetsVault.sol";
import "../../src/core/LetsVaultFactory.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AaveStrategyTest is Test {
    // Constants
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address constant USER = 0x5041ed759Dd4aFc3a72b8192C143F72f4724081A;
    uint256 constant INITIAL_DEPOSIT = 100_000e6; // 100k USDC
    uint256 constant BLOCKS_PER_MONTH = 216_000;
    uint256 constant RAY = 1e27;

    // Contracts
    LetsVaultFactory factory;
    LetsVault vaultImplementation;
    LetsVault vault;
    AaveStrategy strategy;
    IERC20 usdc = IERC20(USDC);
    IPool pool = IPool(AAVE_POOL);

    struct TestState {
        uint256 userUsdcBalance;
        uint256 userShares;
        uint256 vaultTotalAssets;
        uint256 strategyTotalAssets;
        uint256 aTokenBalance;
        uint256 normalizedIncome;
        uint256 blockNumber;
        uint256 feeRecipientBalance;
    }

    TestState public state;

    function setUp() public {
        vm.startPrank(USER);

        // Record initial state
        state.blockNumber = block.number;
        state.normalizedIncome = pool.getReserveNormalizedIncome(USDC);

        console.log("Initial setup:");
        console.log("Block:", state.blockNumber);
        console.log("Normalized income:", state.normalizedIncome);

        // Deploy contracts
        vaultImplementation = new LetsVault();
        factory = new LetsVaultFactory(
            address(vaultImplementation),
            USER, // fee recipient
            1000 // 10% protocol fee
        );

        address vaultAddr = factory.deployVault(USDC, "USDC Vault", "vUSDC", USER);
        vault = LetsVault(vaultAddr);

        strategy = new AaveStrategy(
            USDC,
            "Aave USDC Strategy",
            vaultAddr,
            AAVE_POOL,
            AUSDC,
            USER // fee recipient
        );

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
        state.aTokenBalance = IERC20(AUSDC).balanceOf(address(strategy));
        state.normalizedIncome = pool.getReserveNormalizedIncome(USDC);
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

    function testMonthlyProfit() public withDeposit {
        // Move forward one month
        vm.roll(state.blockNumber + BLOCKS_PER_MONTH);
        vm.warp(block.timestamp + 30 days);

        // Get new normalized income
        uint256 newNormalizedIncome = pool.getReserveNormalizedIncome(USDC);
        uint256 expectedAssets = (INITIAL_DEPOSIT * newNormalizedIncome) / RAY;

        console.log("\nAfter one month:");
        console.log("Initial normalized income:", state.normalizedIncome);
        console.log("New normalized income:", newNormalizedIncome);
        console.log("Expected assets:", expectedAssets);

        // Check strategy calculation matches expected
        uint256 strategyAssets = strategy.estimatedTotalAssets();
        assertApproxEqRel(strategyAssets, expectedAssets, 1e16, "Strategy calculation mismatch"); // 1% tolerance

        vm.startPrank(USER);

        // Process report and check fees
        (uint256 gain, uint256 loss) = vault.processReport(address(strategy));

        // Verify share price increase
        uint256 newShareValue = vault.convertToAssets(vault.balanceOf(USER));
        uint256 valueIncrease = newShareValue - INITIAL_DEPOSIT;

        console.log("\nShare value change:");
        console.log("Initial value:", INITIAL_DEPOSIT);
        console.log("New value:", newShareValue);
        console.log("Increase:", valueIncrease);

        // Assertions
        assertGt(newNormalizedIncome, state.normalizedIncome, "No yield generated");
        assertGt(gain, 0, "No gain");

        vm.stopPrank();
    }

    function testMultipleReports() public withDeposit {
        uint256[] memory normalizedIncomes = new uint256[](3);
        uint256[] memory profits = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            // Move forward one month
            vm.roll(block.number + BLOCKS_PER_MONTH);
            vm.warp(block.timestamp + 30 days);
            normalizedIncomes[i] = pool.getReserveNormalizedIncome(USDC);
            uint256 expectedAssets = (INITIAL_DEPOSIT * normalizedIncomes[i]) / RAY;

            vm.startPrank(USER);
            uint256 preFeeBalance = usdc.balanceOf(USER);
            vault.processReport(address(strategy));
            profits[i] = usdc.balanceOf(USER) - preFeeBalance;

            console.log("\nMonth %s:", i + 1);
            console.log("Normalized income:", normalizedIncomes[i]);
            console.log("Performance fee:", profits[i]);

            vm.stopPrank();
        }

        // Verify increasing yields
        for (uint256 i = 1; i < normalizedIncomes.length; i++) {
            assertGt(normalizedIncomes[i], normalizedIncomes[i - 1], "Yield not increasing");
        }
    }
}
