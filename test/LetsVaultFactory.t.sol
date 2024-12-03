// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/core/LetsVaultFactory.sol";
import "../src/core/LetsVault.sol";
import "../src/mocks/MockERC20.sol";

contract LetsVaultFactoryTest is Test {
    LetsVaultFactory public factory;
    LetsVault public implementation;
    MockERC20 public token;

    address public owner;
    address public feeRecipient;
    address public manager;
    address public user;

    uint16 public constant INITIAL_FEE = 1000; // 10%

    event NewVault(address indexed vault, address indexed asset);
    event UpdateProtocolFee(uint16 oldFee, uint16 newFee);
    event UpdateFeeRecipient(address indexed oldRecipient, address indexed newRecipient);
    event FactoryShutdown();

    function setUp() public {
        // Setup accounts
        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");
        manager = makeAddr("manager");
        user = makeAddr("user");
        console.log("owner: %s", owner);
        console.log("feeRecipient: %s", feeRecipient);
        console.log("manager: %s", manager);
        console.log("user: %s", user);
        vm.startPrank(owner);

        // Deploy mock token
        token = new MockERC20("Test Token", "TEST", 18);

        // Deploy implementation first
        implementation = new LetsVault();

        // Deploy factory after implementation
        factory = new LetsVaultFactory(address(implementation), feeRecipient, INITIAL_FEE);
        console.log("factory: %s", address(factory));

        vm.stopPrank();
    }

    function test_InitialState() public {
        assertEq(address(factory.VAULT_IMPLEMENTATION()), address(implementation));
        assertEq(factory.feeRecipient(), feeRecipient);
        assertEq(factory.protocolFeeBps(), INITIAL_FEE);
        assertEq(factory.owner(), owner);
        assertFalse(factory.isShutdown());
    }

    function test_DeployVault() public {
        vm.startPrank(user);

        string memory name = "Test Vault";
        string memory symbol = "vTEST";

        // Calculate expected vault address
        address expectedVault = factory.calculateVaultAddress(address(token), name, symbol, user);

        // Expect event before deployment
        vm.expectEmit(true, true, false, false);
        emit NewVault(expectedVault, address(token));

        // Deploy vault
        address vault = factory.deployVault(address(token), name, symbol, manager);

        // Verify deployment
        assertEq(vault, expectedVault);
        assertTrue(factory.isVault(vault));
        assertEq(factory.vaultAsset(vault), address(token));

        // Verify vault initialization
        LetsVault deployedVault = LetsVault(vault);
        assertEq(address(deployedVault.underlying()), address(token));
        assertEq(deployedVault.manager(), manager);
        assertEq(deployedVault.name(), name);
        assertEq(deployedVault.symbol(), symbol);

        vm.stopPrank();
    }

    function test_RevertWhen_DeployVaultWithInvalidParams() public {
        vm.startPrank(user);

        // Test invalid asset
        vm.expectRevert("Invalid asset");
        factory.deployVault(address(0), "Test Vault", "vTEST", manager);

        // Test invalid manager
        vm.expectRevert("Invalid manager");
        factory.deployVault(address(token), "Test Vault", "vTEST", address(0));

        vm.stopPrank();
    }

    function test_SetProtocolFee() public {
        vm.startPrank(owner);

        uint16 newFee = 2000; // 20%

        vm.expectEmit(true, true, true, true);
        emit UpdateProtocolFee(INITIAL_FEE, newFee);

        factory.setProtocolFee(newFee);
        assertEq(factory.protocolFeeBps(), newFee);

        vm.stopPrank();
    }

    function test_RevertWhen_SetInvalidProtocolFee() public {
        vm.startPrank(owner);

        // Test fee too high
        vm.expectRevert("Fee too high");
        factory.setProtocolFee(5001); // Over 50%

        vm.stopPrank();

        // Test non-owner
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user));
        factory.setProtocolFee(2000);
        vm.stopPrank();
    }

    function test_SetFeeRecipient() public {
        vm.startPrank(owner);

        address oldRecipient = factory.feeRecipient();
        console.log("oldRecipient: %s", oldRecipient);
        assertEq(oldRecipient, feeRecipient, "Initial fee recipient mismatch");

        address newRecipient = makeAddr("newRecipient");
        console.log("newRecipient: %s", newRecipient);
        require(newRecipient != oldRecipient, "New recipient same as old");

        vm.expectEmit(true, true, false, false);
        emit UpdateFeeRecipient(oldRecipient, newRecipient);
        factory.setFeeRecipient(newRecipient);

        assertEq(factory.feeRecipient(), newRecipient);

        vm.stopPrank();
    }

    function test_RevertWhen_SetInvalidFeeRecipient() public {
        vm.startPrank(owner);

        // Test zero address
        vm.expectRevert("Invalid recipient");
        factory.setFeeRecipient(address(0));

        vm.stopPrank();

        // Test non-owner
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user));
        factory.setFeeRecipient(makeAddr("newRecipient"));
        vm.stopPrank();
    }

    function test_Shutdown() public {
        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit FactoryShutdown();

        factory.shutdown();
        assertTrue(factory.isShutdown());

        // Try to deploy vault after shutdown
        vm.expectRevert("Factory is shutdown");
        factory.deployVault(address(token), "Test Vault", "vTEST", manager);

        vm.stopPrank();
    }

    function test_GetProtocolFeeConfig() public {
        // Deploy vault as user
        vm.startPrank(user);

        address vault = factory.deployVault(address(token), "Test Vault", "vTEST", manager);

        vm.stopPrank();

        // Verify fee config
        (uint16 feeBps, address recipient) = factory.getProtocolFeeConfig(vault);
        assertEq(feeBps, INITIAL_FEE);
        assertEq(recipient, feeRecipient);
    }

    function test_PredictVaultAddress() public {
        string memory name = "Test Vault";
        string memory symbol = "vTEST";

        // Get predicted address
        address predictedAddress = factory.calculateVaultAddress(address(token), name, symbol, user);

        // Deploy vault as factory
        vm.prank(user);
        address deployedVault = factory.deployVault(address(token), name, symbol, user);

        // Verify prediction
        assertEq(deployedVault, predictedAddress);
    }
}
