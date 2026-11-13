// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOracle} from "../interfaces/IOracle.sol";

/// @title Settable price oracle (stands in for Chainlink adapters on testnet).
/// @notice Prices are 18-decimal USD answers per token with an update timestamp.
contract MockOracle is IOracle, Ownable {
    struct Answer {
        uint192 price; // WAD USD
        uint64 updatedAt;
    }

    mapping(address => Answer) public answers;

    event PriceSet(address indexed token, uint256 price);

    constructor() Ownable(msg.sender) {}

    function setPrice(address token, uint256 price) external onlyOwner {
        answers[token] = Answer(uint192(price), uint64(block.timestamp));
        emit PriceSet(token, price);
    }

    function setPriceWithTimestamp(address token, uint256 price, uint64 updatedAt) external onlyOwner {
        answers[token] = Answer(uint192(price), updatedAt);
        emit PriceSet(token, price);
    }

    function getTokenPrice(address token) external view override returns (uint256 price, uint64 updatedAt) {
        Answer memory a = answers[token];
        return (uint256(a.price), a.updatedAt);
    }
}
