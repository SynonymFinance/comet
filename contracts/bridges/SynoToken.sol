// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IWETH } from "syno-bridge-sdk/src/interfaces/IWETH.sol";
import { IWormholeTunnel } from "syno-bridge-sdk/src/interfaces/IWormholeTunnel.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ISynoVault } from "./ISynoVault.sol";

import "syno-bridge-sdk/src/Utils.sol";

contract SynoToken is ERC20 {
    uint8 immutable _decimals;
    ISynoVault immutable _vault;

    error OnlyVault();

    modifier onlyVault() {
        if (msg.sender != address(_vault)) {
            revert OnlyVault();
        }
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
        _vault = ISynoVault(msg.sender);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }

    function vaultApprove(address owner, address spender, uint256 amount) external onlyVault {
        _approve(owner, spender, amount);
    }
}
