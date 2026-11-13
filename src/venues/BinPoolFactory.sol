// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IHub} from "../interfaces/IHub.sol";
import {BinPool} from "./BinPool.sol";

/// @title Factory for discrete-bin pools. Each pool is a BeaconProxy of BinPool.
contract BinPoolFactory is UUPSUpgradeable, AccessControlUpgradeable {
    /// @custom:storage-location erc7201:binpoolfactory.storage.BinPoolFactory
    struct FactoryStorage {
        IHub hub;
        UpgradeableBeacon beacon;
        mapping(bytes32 => address) pools; // key: keccak(token0, token1, binStep)
        address[] poolList;
    }

    // ERC-7201 slot for "binpoolfactory.storage.BinPoolFactory"
    bytes32 private constant FACTORY_STORAGE_SLOT = 0xd4e9999ee99c8369a5d3dbeeced4971364fbc3cb02cc6acf50bc241dce7d0c00;

    function _s() private pure returns (FactoryStorage storage $) {
        assembly {
            $.slot := FACTORY_STORAGE_SLOT
        }
    }

    error ZeroAddress();
    error InvalidStep();
    error PoolExists();
    error PoolNotFound();

    event PoolCreated(address indexed pool, address token0, address token1, uint16 binStepBps, int32 activeId);
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

    function poolKey(address tokenA, address tokenB, uint16 binStepBps) public pure returns (bytes32) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(t0, t1, binStepBps));
    }

    function getPool(address tokenA, address tokenB, uint16 binStepBps) external view returns (address) {
        return _s().pools[poolKey(tokenA, tokenB, binStepBps)];
    }

    function poolCount() external view returns (uint256) {
        return _s().poolList.length;
    }

    function poolAt(uint256 i) external view returns (address) {
        return _s().poolList[i];
    }

    function createPool(address tokenA, address tokenB, uint16 binStepBps, int32 activeId)
        external
        returns (address pool)
    {
        FactoryStorage storage $ = _s();
        if (tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) revert ZeroAddress();
        if (binStepBps == 0 || binStepBps > 100) revert InvalidStep();
        bytes32 key = poolKey(tokenA, tokenB, binStepBps);
        if ($.pools[key] != address(0)) revert PoolExists();
        if ($.hub.paused()) revert BinPool.Paused();

        pool = address(
            new BeaconProxy(
                address($.beacon),
                abi.encodeCall(BinPool.initialize, (address($.hub), tokenA, tokenB, binStepBps, activeId))
            )
        );
        $.pools[key] = pool;
        $.poolList.push(pool);
        $.hub.registerPool(pool, tokenA, tokenB, 2);
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        emit PoolCreated(pool, t0, t1, binStepBps, activeId);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
