// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILetsVaultFactory {
    function initialize(
        address asset,
        string memory name,
        string memory symbol,
        address manager
    ) external;
}