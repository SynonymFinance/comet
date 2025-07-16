// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IWETH } from "syno-bridge-sdk/src/interfaces/IWETH.sol";
import { IWormholeTunnel } from "syno-bridge-sdk/src/interfaces/IWormholeTunnel.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISynoBridge } from "./ISynoBridge.sol";

import "syno-bridge-sdk/src/Utils.sol";

interface IComet {
    function supplyTo(address dst, address asset, uint amount) external;
    function withdrawFrom(address src, address to, address asset, uint amount) external;
}

contract SynoBridge is ISynoBridge {
    using SafeERC20 for IERC20;

    address public admin;
    IWormholeTunnel public wormholeTunnel;
    mapping(uint16 => bytes32) public bridges;
    uint256 public releaseFundsGasLimit = 250_000;
    uint256 public cometSupplyGasLimit = 500_000;
    uint256 public cometWithdrawGasLimit = 700_000;
    IWETH public weth;

    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event SynoVaultSet(uint16 indexed chainId, bytes32 indexed synoVault);
    event WormholeTunnelSet(address indexed wormholeTunnel);

    error FailedToSendNativeToken();
    error InsufficientMsgValue();
    error InvalidAddress();
    error InvalidBridgeMessage();
    error InvalidDeliveryCost();
    error OnlySynoBridgeSender();
    error OnlyWormholeTunnel();
    error Unauthorized();

    modifier onlyWormholeTunnel() {
        if (msg.sender != address(wormholeTunnel)) {
            revert OnlyWormholeTunnel();
        }
        _;
    }

    modifier onlySynoBridgeSender(IWormholeTunnel.MessageSource calldata source) {
        if (source.sender != bridges[source.chainId]) {
            revert OnlySynoBridgeSender();
        }
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert Unauthorized();
        }
        _;
    }

    constructor(
        address admin_,
        address wormholeTunnel_,
        address weth_
    ) {
        admin = admin_;
        wormholeTunnel = IWormholeTunnel(wormholeTunnel_);
        weth = IWETH(weth_);

        emit AdminTransferred(address(0), admin_);
    }

    /**
     * @notice Transfers the admin rights to a new address
     * @param newAdmin The address that will become the new admin
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();

        address oldAdmin = admin;
        admin = newAdmin;
        emit AdminTransferred(oldAdmin, newAdmin);
    }

    function setWormholeTunnel(address wormholeTunnel_) external onlyAdmin {
        wormholeTunnel = IWormholeTunnel(wormholeTunnel_);
        emit WormholeTunnelSet(wormholeTunnel_);
    }

    function setCometSupplyGasLimit(uint256 value) external onlyAdmin {
        cometSupplyGasLimit = value;
    }

    function setCometWithdrawGasLimit(uint256 value) external onlyAdmin {
        cometWithdrawGasLimit = value;
    }

    function setReleaseFundsGasLimit(uint256 value) external onlyAdmin {
        releaseFundsGasLimit = value;
    }

    function setSynoBridge(uint16 synoBridgeChainId_, bytes32 synoBridge_) external override onlyAdmin {
        bridges[synoBridgeChainId_] = synoBridge_;
    }

    function getReturnMessageCost(uint16 chainId_) external view override returns (uint256) {
        return wormholeTunnel.getMessageCost(chainId_, releaseFundsGasLimit, 0, true);
    }

    function getActionCost(ISynoBridge.SynoBridgeAction action, uint16 cometChainId, uint256 costForReturnDelivery) external view returns (uint256) {
        if (action == ISynoBridge.SynoBridgeAction.SUPPLY) {
            return getSupplyCost(cometChainId);
        } else if (action == ISynoBridge.SynoBridgeAction.WITHDRAW) {
            return getWithdrawCost(cometChainId, costForReturnDelivery);
        } else {
            revert InvalidBridgeMessage();
        }
    }

    function getSupplyCost(uint16 cometChainId) public view returns (uint256) {
        return wormholeTunnel.getMessageCost(cometChainId, cometSupplyGasLimit, 0, true);
    }

    function getWithdrawCost(uint16 cometChainId, uint256 costForReturnDelivery) public view returns (uint256) {
        return wormholeTunnel.getMessageCost(cometChainId, cometWithdrawGasLimit, costForReturnDelivery, false);
    }

    function receiveSynoBridgeMessage(
        IWormholeTunnel.MessageSource calldata source_,
        IERC20 asset_,
        uint256 amount_,
        bytes calldata payload_
    ) external payable override {
        if (msg.sender != address(wormholeTunnel)) revert InvalidBridgeMessage();
        if (source_.sender == bytes32(0) || source_.sender != bridges[source_.chainId]) revert InvalidBridgeMessage();

        ISynoBridge.SynoBridgeMessage memory message = abi.decode(payload_, (ISynoBridge.SynoBridgeMessage));

        if (message.action == ISynoBridge.SynoBridgeAction.SUPPLY) {
            asset_.safeTransferFrom(msg.sender, address(this), amount_);
            asset_.approve(message.comet, amount_);
            IComet(message.comet).supplyTo(message.recipient, address(asset_), amount_);
        } else if (message.action == ISynoBridge.SynoBridgeAction.WITHDRAW) {
            IERC20 thisChainAsset = IERC20(wormholeTunnel.getTokenAddressOnThisChain(source_.chainId, message.asset));

            // process the withdrawal
            IComet(message.comet).withdrawFrom(message.recipient, address(this), address(thisChainAsset), message.amount);
            sendReleaseFundsMessage(
                source_.chainId,
                toWormholeFormat(message.recipient),
                address(thisChainAsset),
                message.amount,
                address(0) // no sender since this is a return message
            );
        } else {
            revert InvalidBridgeMessage();
        }
    }

    function userActions(uint16 cometChainId, address comet, ISynoBridge.SynoBridgeAction action, IERC20 asset, uint256 amount, uint256 costForReturnDelivery) external payable {
        if (
            cometChainId == wormholeTunnel.chainId() ||
            cometChainId == 0 ||
            comet == address(0) ||
            asset == IERC20(address(0)) ||
            amount == 0 ||
            bridges[cometChainId] == bytes32(0)
        ) revert InvalidBridgeMessage();

        if (action == ISynoBridge.SynoBridgeAction.SUPPLY) {
            if (costForReturnDelivery > 0) {
                revert InvalidDeliveryCost();
            }
            asset.safeTransferFrom(msg.sender, address(this), amount);
            asset.approve(address(wormholeTunnel), amount);
        } else if (action == SynoBridgeAction.WITHDRAW && costForReturnDelivery == 0) {
            revert InvalidDeliveryCost();
        }

        sendMessage(cometChainId, comet, action, asset, amount, costForReturnDelivery);
    }

    function withdrawToChain(address comet, address asset, uint256 amount, uint16 targetChain, bytes32 recipient) external payable override {
        if (comet == address(0) || asset == address(0) || amount == 0) revert InvalidBridgeMessage();
        // process the withdrawal
        IComet(comet).withdrawFrom(msg.sender, address(this), asset, amount);
        sendReleaseFundsMessage(
            targetChain,
            recipient,
            asset,
            amount,
            msg.sender
        );
    }

    function sendReleaseFundsMessage(
        uint16 chainId,
        bytes32 recipient,
        address asset,
        uint256 amount,
        address sender
    ) internal {
        uint256 returnMessageCost = wormholeTunnel.getMessageCost(
            chainId,
            releaseFundsGasLimit,
            0, // no return messages, so no receiver value
            true // with token transfer
        );
        if (msg.value < returnMessageCost) revert InsufficientMsgValue();

        IERC20(asset).approve(address(wormholeTunnel), amount);

        // send the funds to the user
        IWormholeTunnel.TunnelMessage memory tunnelMessage;
        tunnelMessage.source = IWormholeTunnel.MessageSource({
            chainId: wormholeTunnel.chainId(),
            sender: toWormholeFormat(address(this)),
            refundRecipient: recipient
        });
        tunnelMessage.target = IWormholeTunnel.MessageTarget({
            chainId: chainId,
            recipient: recipient,
            selector: 0x0, // zero selector indicating no function call
            payload: bytes("") // no payload required since no call is made
        });
        tunnelMessage.token = toWormholeFormat(asset);
        tunnelMessage.amount = amount;
        wormholeTunnel.sendEvmMessage{value: returnMessageCost}(tunnelMessage, releaseFundsGasLimit);
        if (msg.value > returnMessageCost && sender != address(0)) {
            // send any overpaid eth to sender
            (bool success, ) = sender.call{value: msg.value - returnMessageCost}("");
            if (!success) {
                revert FailedToSendNativeToken();
            }
        }
    }

    function sendMessage(
        uint16 cometChainId,
        address comet,
        ISynoBridge.SynoBridgeAction action,
        IERC20 asset,
        uint256 amount,
        uint256 costForReturnDelivery
    ) internal {
        IWormholeTunnel.TunnelMessage memory message;

        message.source.refundRecipient = toWormholeFormat(msg.sender);
        message.source.sender = toWormholeFormat(address(this));

        message.target.chainId = cometChainId;
        message.target.recipient = bridges[cometChainId];
        message.target.selector = ISynoBridge.receiveSynoBridgeMessage.selector;
        message.target.payload = abi.encode(ISynoBridge.SynoBridgeMessage({
            action: action,
            comet: comet,
            asset: toWormholeFormat(address(asset)),
            amount: amount,
            recipient: msg.sender
        }));

        uint256 cost;
        uint256 gasLimit;
        if (action == ISynoBridge.SynoBridgeAction.SUPPLY) {
            message.token = toWormholeFormat(address(asset));
            message.amount = amount;
            message.finality = IWormholeTunnel.MessageFinality.FINALIZED;
            cost = getSupplyCost(cometChainId);
            gasLimit = cometSupplyGasLimit;
        } else if (action == ISynoBridge.SynoBridgeAction.WITHDRAW) {
            message.finality = IWormholeTunnel.MessageFinality.INSTANT;
            cost = getWithdrawCost(cometChainId, costForReturnDelivery);
            gasLimit = cometWithdrawGasLimit;
        }

        if (msg.value < cost) {
            revert InsufficientMsgValue();
        }

        wormholeTunnel.sendEvmMessage{value: cost}(message, gasLimit);

        // return any overpaid msg.value
        if (msg.value > cost) {
            (bool success, ) = msg.sender.call{value: msg.value - cost}("");
            if (!success) {
                revert FailedToSendNativeToken();
            }
        }
    }

    function withdrawFromBridge(address asset, uint256 amount, address recipient) external override onlyAdmin {
        if (asset == address(0)) {
            if (amount > address(this).balance) {
                amount = address(this).balance;
            }
            (bool success, ) = recipient.call{value: amount}("");
            if (!success) {
                revert FailedToSendNativeToken();
            }
        } else {
            IERC20 assetIERC20 = IERC20(asset);
            if (amount > assetIERC20.balanceOf(address(this))) {
                amount = assetIERC20.balanceOf(address(this));
            }
            assetIERC20.safeTransfer(recipient, amount);
        }
    }
}
