// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title Mock ERC20 Token
 * @notice A basic ERC20 token for testing purposes
 */
contract MockERC20 is ERC20 {
    uint8 private _decimals;
    
    /**
     * @notice Constructor
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param decimals_ Token decimals (default 18 if not specified)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = 18;
    }

    /**
     * @notice Returns the number of decimals used for token
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Mint tokens to an address
     * @param to Address to mint to
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from an address
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    /**
     * @notice Mint tokens to msg.sender (faucet function)
     * @param amount Amount to mint
     */
    function faucet(uint256 amount) external {
        _mint(msg.sender, amount);
    }

    /**
     * @notice Mint specific amount with decimals
     * @param to Address to mint to
     * @param amount Amount to mint (in whole tokens)
     */
    function mintWithDecimals(address to, uint256 amount) external {
        _mint(to, amount * 10**_decimals);
    }
}
