// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IWormholeTunnel } from "syno-bridge-sdk/src/interfaces/IWormholeTunnel.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISynoBridge {
    enum SynoBridgeAction {
        SUPPLY,
        WITHDRAW
    }

    struct SynoBridgeMessage {
        SynoBridgeAction action;
        address comet;
        bytes32 asset;
        uint256 amount;
        address recipient;
    }

    function getActionCost(SynoBridgeAction action, uint16 cometChainId, uint256 costForReturnDelivery) external view returns (uint256);
    function getSupplyCost(uint16 cometChainId) external view returns (uint256);
    function getWithdrawCost(uint16 cometChainId, uint256 costForReturnDelivery) external view returns (uint256);
    function userActions(uint16 cometChainId, address comet, SynoBridgeAction action, IERC20 asset, uint256 amount, uint256 costForReturnDelivery) external payable;
    function withdrawToChain(address comet, address asset, uint256 amount, uint16 targetChain, bytes32 recipient) external payable;
    function setWormholeTunnel(address wormholeTunnel_) external;
    function setSynoBridge(uint16 chainId_, bytes32 synoBridge_) external;
    function getReturnMessageCost(uint16 chainId_) external view returns (uint256);
    function receiveSynoBridgeMessage(
        IWormholeTunnel.MessageSource calldata source_,
        IERC20 asset_,
        uint256 amount_,
        bytes calldata payload_
    ) external payable;
    function withdrawFromBridge(address asset, uint256 amount, address recipient) external;
}
