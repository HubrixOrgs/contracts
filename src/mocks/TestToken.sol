// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Generic testnet ERC-20 with a public faucet and owner mint.
contract TestToken is ERC20, Ownable {
    uint256 public constant FAUCET_AMOUNT = 10_000 ether;
    mapping(address => uint256) public lastDrip;

    event FaucetDrip(address indexed account, uint256 amount);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {}

    /// @notice Public faucet: 10,000 tokens per address per block.
    function faucet() external {
        require(lastDrip[msg.sender] < block.number, "rate limited");
        lastDrip[msg.sender] = block.number;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit FaucetDrip(msg.sender, FAUCET_AMOUNT);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
