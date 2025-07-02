// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IWormholeTunnel } from "@syno/interfaces/IWormholeTunnel.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISynoBridge {
    function setWormholeTunnel(address wormholeTunnel_) external;
    function setSynoVault(uint16 chainId_, bytes32 synoVault_) external;
    function getReturnMessageCost(uint16 chainId_) external view returns (uint256);
    function receiveSynoBridgeMessage(
        IWormholeTunnel.MessageSource calldata source_,
        IERC20 asset_,
        uint256 amount_,
        bytes calldata payload_
    ) external payable;
}
