// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Price oracle interface (18-decimal USD answers).
/// On mainnet this is a Chainlink adapter; on testnet a settable mock.
interface IOracle {
    /// @notice USD price of `token` with 18 decimals, plus the feed timestamp.
    function getTokenPrice(address token) external view returns (uint256 price, uint64 updatedAt);
}
