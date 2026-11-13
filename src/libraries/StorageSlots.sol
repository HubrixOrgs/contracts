// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Canonical ERC-7201 namespaced storage slot derivation.
library StorageSlots {
    /// @notice slot = keccak256(abi.encode(uint256(keccak256(ns)) - 1)) & ~bytes32(uint256(0xff))
    function slotFor(string memory ns) internal pure returns (bytes32 s) {
        s = keccak256(abi.encode(uint256(keccak256(bytes(ns))) - 1)) & ~bytes32(uint256(0xff));
    }
}
