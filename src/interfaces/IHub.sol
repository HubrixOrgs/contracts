// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Central registry and configuration for the protocol.
interface IHub {
    struct AssetInfo {
        uint8 class; // 0 = STANDARD, 1 = STOCK
        address oracle;
        bool active;
    }

    // --- views ---
    function paused() external view returns (bool);
    function protocolFeeBps() external view returns (uint24);
    function maxFeeBps() external view returns (uint24);
    function feeRecipient() external view returns (address);
    function assetInfo(address token) external view returns (AssetInfo memory);
    function pairPools(address tokenA, address tokenB) external view returns (address[] memory);
    function poolVenue(address pool) external view returns (uint8);
    function isRegisteredPool(address pool) external view returns (bool);

    // --- registration ---
    function registerPool(address pool, address tokenA, address tokenB, uint8 venue) external;
}
