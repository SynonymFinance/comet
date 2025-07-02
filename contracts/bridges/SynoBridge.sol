// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IWormholeTunnel } from "@syno/interfaces/IWormholeTunnel.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SynoBridgeAction, SynoBridgeMessage } from "./SynoBridgeStructs.sol";
import { ISynoBridge } from "./ISynoBridge.sol";
import "forge-std/console.sol";

import "@syno/Utils.sol";

interface IComet {
    function supplyTo(address dst, address asset, uint amount) external;
    function withdrawFrom(address src, address to, address asset, uint amount) external;
}

contract SynoBridge is ISynoBridge {
    using SafeERC20 for IERC20;

    address public admin;
    IWormholeTunnel public wormholeTunnel;
    mapping(uint16 => bytes32) public synoVaults;
    uint256 public RELEASE_FUNDS_GAS_LIMIT = 150_000;

    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event SynoVaultSet(uint16 indexed chainId, bytes32 indexed synoVault);
    event WormholeTunnelSet(address indexed wormholeTunnel);

    error InsufficientMsgValue();
    error InvalidBridgeMessage();
    error InvalidAddress();
    error Unauthorized();

    constructor(
        address admin_,
        address wormholeTunnel_
    ) {
        admin = admin_;
        wormholeTunnel = IWormholeTunnel(wormholeTunnel_);

        emit AdminTransferred(address(0), admin_);
    }

    /**
     * @notice Transfers the admin rights to a new address
     * @param newAdmin The address that will become the new admin
     */
    function transferAdmin(address newAdmin) external {
        if (msg.sender != admin) revert Unauthorized();
        if (newAdmin == address(0)) revert InvalidAddress();

        address oldAdmin = admin;
        admin = newAdmin;
        emit AdminTransferred(oldAdmin, newAdmin);
    }

    function setWormholeTunnel(address wormholeTunnel_) external override {
        if (msg.sender != admin) revert Unauthorized();
        wormholeTunnel = IWormholeTunnel(wormholeTunnel_);
        emit WormholeTunnelSet(wormholeTunnel_);
    }

    function setSynoVault(uint16 chainId_, bytes32 synoVault_) external override {
        if (msg.sender != admin) revert Unauthorized();
        synoVaults[chainId_] = synoVault_;
        emit SynoVaultSet(chainId_, synoVault_);
    }

    function getReturnMessageCost(uint16 chainId_) external view override returns (uint256) {
        return wormholeTunnel.getMessageCost(chainId_, RELEASE_FUNDS_GAS_LIMIT, 0, true);
    }

    function receiveSynoBridgeMessage(
        IWormholeTunnel.MessageSource calldata source_,
        IERC20 asset_,
        uint256 amount_,
        bytes calldata payload_
    ) external payable override {
        if (msg.sender != address(wormholeTunnel)) revert InvalidBridgeMessage();
        if (source_.sender == bytes32(0) || source_.sender != synoVaults[source_.chainId]) revert InvalidBridgeMessage();

        SynoBridgeMessage memory message = abi.decode(payload_, (SynoBridgeMessage));

        if (message.action == SynoBridgeAction.SUPPLY) {
            asset_.safeTransferFrom(msg.sender, address(this), amount_);
            asset_.approve(message.comet, amount_);
            IComet(message.comet).supplyTo(message.recipient, address(asset_), amount_);
        } else if (message.action == SynoBridgeAction.WITHDRAW) {
            uint256 returnMessageCost = wormholeTunnel.getMessageCost(
                source_.chainId,
                RELEASE_FUNDS_GAS_LIMIT,
                0, // no return messages, so no receiver value
                true // with token transfer
            );
            if (msg.value < returnMessageCost) revert InsufficientMsgValue();

            // process the withdrawal
            IComet(message.comet).withdrawFrom(message.recipient, address(this), address(asset_), amount_);
            asset_.approve(address(wormholeTunnel), amount_);

            // send the funds to the user
            IWormholeTunnel.TunnelMessage memory tunnelMessage;
            tunnelMessage.source = IWormholeTunnel.MessageSource({
                chainId: wormholeTunnel.chainId(),
                sender: toWormholeFormat(address(this)),
                refundRecipient: source_.refundRecipient
            });
            tunnelMessage.target = IWormholeTunnel.MessageTarget({
                chainId: source_.chainId,
                recipient: toWormholeFormat(message.recipient),
                selector: 0x0, // zero selector indicating no function call
                payload: bytes("") // no payload required since no call is made
            });
            tunnelMessage.token = toWormholeFormat(address(asset_));
            tunnelMessage.amount = amount_;
            // any repaid msg.value will be received by the refundRecipient
            wormholeTunnel.sendEvmMessage{value: msg.value}(tunnelMessage, RELEASE_FUNDS_GAS_LIMIT);
        } else {
            revert InvalidBridgeMessage();
        }
    }
}
