// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Canonical WETH interface.
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}
