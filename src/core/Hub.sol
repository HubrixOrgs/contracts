// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IHub} from "../interfaces/IHub.sol";

/// @title Central registry: assets, oracles, pools, roles, protocol fees, pause.
/// @notice All logic contracts read configuration from here.
contract Hub is IHub, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    // ---------- roles ----------
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ---------- venue ids ----------
    uint8 public constant VENUE_HOOK = 1;
    uint8 public constant VENUE_BIN = 2;
    uint8 public constant VENUE_RANGE = 3;

    // ---------- ERC-7201 storage ----------
    /// @custom:storage-location erc7201:hub.storage.Hub
    struct HubStorage {
        mapping(address => AssetInfo) assets;
        address[] assetsList;
        mapping(bytes32 => address[]) poolsByPair;
        mapping(address => uint8) poolVenue;
        address[] allPools;
        uint24 protocolFeeBps;
        uint24 maxFeeBps;
        address feeRecipient;
        address router;
        bool pausedFlag;
    }

    // ERC-7201 slot for "hub.storage.Hub" = 0x9346b2ad...b5a5500
    bytes32 private constant HUB_STORAGE_SLOT = 0x9346b2ad433618b0a2f0fe02b435c598104e2207c81334e95f4401170b5a5500;

    function _s() private pure returns (HubStorage storage $) {
        assembly {
            $.slot := HUB_STORAGE_SLOT
        }
    }

    // ---------- errors ----------
    error ZeroAddress();
    error InvalidClass();
    error FeeTooHigh();
    error PoolAlreadyRegistered();
    error NotPool();

    // ---------- events ----------
    event AssetRegistered(address indexed token, uint8 class, address oracle);
    event AssetDelisted(address indexed token);
    event PoolRegistered(address indexed pool, address indexed tokenA, address indexed tokenB, uint8 venue);
    event ProtocolFeeUpdated(uint24 bps);
    event MaxFeeUpdated(uint24 bps);
    event FeeRecipientUpdated(address account);
    event RouterUpdated(address router);
    event Paused();
    event Unpaused();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address feeRecipient_) external initializer {
        if (admin == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        HubStorage storage $ = _s();
        $.protocolFeeBps = 500; // 5%
        $.maxFeeBps = 1_000; // 10%
        $.feeRecipient = feeRecipient_;
    }

    // ---------- asset registry ----------

    function registerAsset(address token, uint8 class, address oracle) external onlyRole(OPERATOR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (class > 1) revert InvalidClass();
        HubStorage storage $ = _s();
        AssetInfo storage info = $.assets[token];
        if (!info.active) {
            $.assetsList.push(token);
        }
        info.class = class;
        info.oracle = oracle;
        info.active = true;
        emit AssetRegistered(token, class, oracle);
    }

    function delistAsset(address token) external onlyRole(OPERATOR_ROLE) {
        _s().assets[token].active = false;
        emit AssetDelisted(token);
    }

    // ---------- pool registry ----------

    function registerPool(address pool, address tokenA, address tokenB, uint8 venue) external {
        HubStorage storage $ = _s();
        if (pool == address(0) || tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        if (venue < VENUE_HOOK || venue > VENUE_RANGE) revert InvalidClass();
        if (msg.sender != $.router && !hasRole(OPERATOR_ROLE, msg.sender)) revert Unauthorized();
        if ($.poolVenue[pool] != 0) revert PoolAlreadyRegistered();
        $.poolVenue[pool] = venue;
        $.allPools.push(pool);
        bytes32 key = _pairKey(tokenA, tokenB);
        $.poolsByPair[key].push(pool);
        emit PoolRegistered(pool, tokenA, tokenB, venue);
    }

    error Unauthorized();

    // ---------- configuration ----------

    function setProtocolFeeBps(uint24 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        HubStorage storage $ = _s();
        if (bps > $.maxFeeBps) revert FeeTooHigh();
        $.protocolFeeBps = bps;
        emit ProtocolFeeUpdated(bps);
    }

    function setMaxFeeBps(uint24 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert FeeTooHigh();
        _s().maxFeeBps = bps;
        emit MaxFeeUpdated(bps);
    }

    function setFeeRecipient(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _s().feeRecipient = account;
        emit FeeRecipientUpdated(account);
    }

    function setRouter(address router_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _s().router = router_;
        emit RouterUpdated(router_);
    }

    // ---------- pause ----------

    function pause() external onlyRole(PAUSER_ROLE) {
        _s().pausedFlag = true;
        emit Paused();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _s().pausedFlag = false;
        emit Unpaused();
    }

    // ---------- views ----------

    function paused() public view override returns (bool) {
        return _s().pausedFlag;
    }

    function protocolFeeBps() external view returns (uint24) {
        return _s().protocolFeeBps;
    }

    function maxFeeBps() external view returns (uint24) {
        return _s().maxFeeBps;
    }

    function feeRecipient() external view returns (address) {
        return _s().feeRecipient;
    }

    function router() external view returns (address) {
        return _s().router;
    }

    function assetInfo(address token) external view returns (AssetInfo memory) {
        return _s().assets[token];
    }

    function assetsCount() external view returns (uint256) {
        return _s().assetsList.length;
    }

    function assetAt(uint256 i) external view returns (address) {
        return _s().assetsList[i];
    }

    function pairPools(address tokenA, address tokenB) public view returns (address[] memory) {
        return _s().poolsByPair[_pairKey(tokenA, tokenB)];
    }

    function poolVenue(address pool) public view returns (uint8) {
        return _s().poolVenue[pool];
    }

    function isRegisteredPool(address pool) external view returns (bool) {
        return _s().poolVenue[pool] != 0;
    }

    function allPools() external view returns (address[] memory) {
        return _s().allPools;
    }

    function _pairKey(address a, address b) internal pure returns (bytes32) {
        (address lo, address hi) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encodePacked(lo, hi));
    }

    // ---------- upgrades ----------

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
