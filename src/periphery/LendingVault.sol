// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ERC-4626 stablecoin vault. Sole borrower is the CreditManager.
contract LendingVault is ERC4626Upgradeable, UUPSUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:lendingvault.storage.LendingVault
    struct VaultStorage {
        address creditManager;
    }

    // ERC-7201 slot for "lendingvault.storage.LendingVault"
    bytes32 private constant VAULT_STORAGE_SLOT = 0x20a78c78763d44dbf41916e211ac7d8aa01bb549af4ff791ec64d7daa754f700;

    function _s() private pure returns (VaultStorage storage $) {
        assembly {
            $.slot := VAULT_STORAGE_SLOT
        }
    }

    error ZeroAddress();
    error NotCreditManager();

    event CreditManagerUpdated(address account);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address asset_, address admin, address creditManager_) external initializer {
        if (asset_ == address(0) || admin == address(0) || creditManager_ == address(0)) revert ZeroAddress();
        __ERC20_init("Lending Vault Share", "LVS");
        __ERC4626_init(IERC20(asset_));
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _s().creditManager = creditManager_;
    }

    function creditManager() external view returns (address) {
        return _s().creditManager;
    }

    function setCreditManager(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _s().creditManager = account;
        emit CreditManagerUpdated(account);
    }

    /// @notice Sole-borrower hook: pull `amount` of the asset to `to`.
    function borrowTo(address to, uint256 amount) external {
        if (msg.sender != _s().creditManager) revert NotCreditManager();
        IERC20(asset()).safeTransfer(to, amount);
    }

    /// @notice Sole-borrower hook: return `amount` of the asset from the manager.
    function repayFrom(uint256 amount) external {
        if (msg.sender != _s().creditManager) revert NotCreditManager();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
