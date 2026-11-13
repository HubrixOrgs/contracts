// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IHub} from "../interfaces/IHub.sol";
import {RangePool} from "./RangePool.sol";

/// @title Factory for single-range pools. Each pool is a BeaconProxy of RangePool.
contract RangePoolFactory is UUPSUpgradeable, AccessControlUpgradeable {
    /// @custom:storage-location erc7201:rangepoolfactory.storage.RangePoolFactory
    struct FactoryStorage {
        IHub hub;
        UpgradeableBeacon beacon;
        mapping(bytes32 => address) pools; // key: keccak(token0, token1)
        address[] poolList;
    }

    // ERC-7201 slot for "rangepoolfactory.storage.RangePoolFactory"
    bytes32 private constant FACTORY_STORAGE_SLOT = 0x03bfce5b5195ed84f6e38d6e5c696e181c22791509b242f9957741f496911200;

    function _s() private pure returns (FactoryStorage storage $) {
        assembly {
            $.slot := FACTORY_STORAGE_SLOT
        }
    }

    error ZeroAddress();
    error InvalidRange();
    error PoolExists();

    event PoolCreated(
        address indexed pool,
        address token0,
        address token1,
        uint24 rangeBps,
        uint24 baseFeeBps,
        uint24 launchFeeStartBps,
        uint32 launchWindow
    );
    event ImplementationUpgraded(address implementation);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address hub_, address impl, address admin) external initializer {
        if (hub_ == address(0) || impl == address(0) || admin == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        FactoryStorage storage $ = _s();
        $.hub = IHub(hub_);
        $.beacon = new UpgradeableBeacon(impl, address(this));
    }

    function hub() external view returns (address) {
        return address(_s().hub);
    }

    function beacon() external view returns (address) {
        return address(_s().beacon);
    }

    function implementation() external view returns (address) {
        return _s().beacon.implementation();
    }

    function upgradeImplementation(address newImpl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _s().beacon.upgradeTo(newImpl);
        emit ImplementationUpgraded(newImpl);
    }

    function getPool(address tokenA, address tokenB) external view returns (address) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _s().pools[keccak256(abi.encode(t0, t1))];
    }

    function poolCount() external view returns (uint256) {
        return _s().poolList.length;
    }

    function poolAt(uint256 i) external view returns (address) {
        return _s().poolList[i];
    }

    /// @notice One range pool per token pair. `sqrtPriceX96` is the anchor price.
    function createPool(
        address tokenA,
        address tokenB,
        uint160 sqrtPriceX96,
        uint24 rangeBps,
        uint24 baseFeeBps,
        uint24 launchFeeStartBps,
        uint32 launchWindow
    ) external returns (address pool) {
        FactoryStorage storage $ = _s();
        if (tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) revert ZeroAddress();
        if (rangeBps == 0 || rangeBps > 5_000) revert InvalidRange();
        if (sqrtPriceX96 == 0) revert ZeroAddress();
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 key = keccak256(abi.encode(t0, t1));
        if ($.pools[key] != address(0)) revert PoolExists();
        if ($.hub.paused()) revert RangePool.Paused();

        pool = address(
            new BeaconProxy(
                address($.beacon),
                abi.encodeCall(
                    RangePool.initialize,
                    (
                        address($.hub), t0, t1, sqrtPriceX96, rangeBps, baseFeeBps, launchFeeStartBps, launchWindow
                    )
                )
            )
        );
        $.pools[key] = pool;
        $.poolList.push(pool);
        $.hub.registerPool(pool, tokenA, tokenB, 3);
        emit PoolCreated(pool, t0, t1, rangeBps, baseFeeBps, launchFeeStartBps, launchWindow);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
