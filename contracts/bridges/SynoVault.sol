// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IWETH} from "@syno/interfaces/IWETH.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SynoBridgeAction, SynoBridgeMessage} from "./SynoBridgeStructs.sol";

import {IWormholeTunnel} from "@syno/interfaces/IWormholeTunnel.sol";
import {ISynoBridge} from "./ISynoBridge.sol";

import "@syno/Utils.sol";

contract SynoVault is Initializable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    IWETH public weth;
    uint16 public synoBridgeChainId;
    address public synoBridge;
    IWormholeTunnel public wormholeTunnel;
    uint256 public cometActionGasLimit;

    error OnlyWormholeTunnel();
    error OnlySynoBridgeSender();
    error InsufficientMsgValue();
    error FailedToSendNativeToken();
    error InvalidDeliveryCost();

    modifier onlyWormholeTunnel() {
        if (msg.sender != address(wormholeTunnel)) {
            revert OnlyWormholeTunnel();
        }
        _;
    }

    modifier onlySynoBridgeSender(IWormholeTunnel.MessageSource calldata source) {
        if (source.sender != toWormholeFormat(synoBridge) || source.chainId != synoBridgeChainId) {
            revert OnlySynoBridgeSender();
        }
        _;
    }

    /**
     * @notice Spoke initializer - Initializes a new spoke with given parameters
     * @param synoBridgeChainId_: Chain ID of the SynoBridge
     * @param synoBridge_: Contract address of the SynoBridge contract
     * @param wormholeTunnel_: The Wormhole tunnel contract
     */
    function initialize(
        uint16 synoBridgeChainId_,
        address synoBridge_,
        IWormholeTunnel wormholeTunnel_,
        IWETH _weth
    ) public initializer {
        OwnableUpgradeable.__Ownable_init(msg.sender);
        PausableUpgradeable.__Pausable_init();
        synoBridgeChainId = synoBridgeChainId_;
        synoBridge = synoBridge_;
        wormholeTunnel = wormholeTunnel_;
        cometActionGasLimit = 500_000;

        weth = _weth;
    }

    function setCometActionGasLimit(uint256 value) external onlyOwner {
        cometActionGasLimit = value;
    }

    function setWeth(IWETH weth_) external onlyOwner {
        weth = weth_;
    }

    function setWormholeTunnel(IWormholeTunnel wormholeTunnel_) external onlyOwner {
        wormholeTunnel = wormholeTunnel_;
    }

    function setSynoBridge(uint16 synoBridgeChainId_, address synoBridge_) external onlyOwner {
        synoBridgeChainId = synoBridgeChainId_;
        synoBridge = synoBridge_;
    }

    function userActions(address comet, SynoBridgeAction action, IERC20 asset, uint256 amount, uint256 costForReturnDelivery) external payable {
        if (action == SynoBridgeAction.SUPPLY) {
            if (costForReturnDelivery > 0) {
                revert InvalidDeliveryCost();
            }
            asset.safeTransferFrom(msg.sender, address(this), amount);
            asset.approve(address(wormholeTunnel), amount);
        } else if (action == SynoBridgeAction.WITHDRAW && costForReturnDelivery == 0) {
            revert InvalidDeliveryCost();
        }

        sendMessage(comet, action, asset, amount, costForReturnDelivery);
    }

    function getActionCost(SynoBridgeAction action, uint256 costForReturnDelivery) external view returns (uint256) {
        if (action == SynoBridgeAction.SUPPLY) {
            return getSupplyCost();
        } else if (action == SynoBridgeAction.WITHDRAW && costForReturnDelivery == 0) {
            return getWithdrawCost(costForReturnDelivery);
        }
    }

    function getSupplyCost() public view returns (uint256) {
        return wormholeTunnel.getMessageCost(synoBridgeChainId, cometActionGasLimit, 0, true);
    }

    function getWithdrawCost(uint256 costForReturnDelivery) public view returns (uint256) {
        return wormholeTunnel.getMessageCost(synoBridgeChainId, cometActionGasLimit, costForReturnDelivery, false);
    }

    function sendMessage(address comet, SynoBridgeAction action, IERC20 asset, uint256 amount, uint256 costForReturnDelivery) internal {
        IWormholeTunnel.TunnelMessage memory message;

        message.source.refundRecipient = toWormholeFormat(msg.sender);
        message.source.sender = toWormholeFormat(address(this));

        message.target.chainId = synoBridgeChainId;
        message.target.recipient = toWormholeFormat(synoBridge);
        message.target.selector = ISynoBridge.receiveSynoBridgeMessage.selector;
        message.target.payload = abi.encode(SynoBridgeMessage({
            action: action,
            comet: comet,
            asset: address(asset),
            amount: amount,
            recipient: msg.sender
        }));

        uint256 cost;
        if (action == SynoBridgeAction.SUPPLY) {
            message.token = toWormholeFormat(address(asset));
            message.amount = amount;
            cost = wormholeTunnel.getMessageCost(synoBridgeChainId, cometActionGasLimit, 0, true);
        } else if (action == SynoBridgeAction.WITHDRAW) {
            cost = wormholeTunnel.getMessageCost(synoBridgeChainId, cometActionGasLimit, costForReturnDelivery, false);
        }

        if (msg.value < cost) {
            revert InsufficientMsgValue();
        }

        wormholeTunnel.sendEvmMessage{value: cost}(message, cometActionGasLimit);

        // return any overpaid msg.value
        if (msg.value > cost) {
            (bool success, ) = msg.sender.call{value: msg.value - cost}("");
            if (!success) {
                revert FailedToSendNativeToken();
            }
        }
    }

    /**
     * @notice Pauses the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice receive function to receive unwrapped native asset
     */
    receive() external payable {}

    /**
     * @notice fallback function to receive unwrapped native asset
     */
    fallback() external payable {}
}
