// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IWETH } from "syno-bridge-sdk/src/interfaces/IWETH.sol";
import { IWormholeTunnel } from "syno-bridge-sdk/src/interfaces/IWormholeTunnel.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISynoVault } from "./ISynoVault.sol";
import { SynoToken } from "./SynoToken.sol";

import "syno-bridge-sdk/src/Utils.sol";

contract SynoVault is ISynoVault {
    using SafeERC20 for IERC20;

    address public admin;
    IWormholeTunnel public wormholeTunnel;
    mapping(uint16 => bytes32) public vaults;
    uint256 public baseTransferGasLimit = 250_000;
    uint256 public contractCreationGasLimit = 500_000;
    mapping(address => bytes32) public contractToAssetId;
    mapping(address => bytes32) public underlyingTokenToAssetId;
    // some chains can use faster finality safely when there is no reorg risk or the reorg risk is low (e.g. Arbitrum)
    IWormholeTunnel.MessageFinality public defaultFinality = IWormholeTunnel.MessageFinality.FINALIZED;

    // token balances and allowances
    mapping(bytes32 => AssetState) public assetStates;

    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event SynoVaultSet(uint16 indexed chainId, bytes32 indexed synoVault);
    event WormholeTunnelSet(address indexed wormholeTunnel);

    error FailedToSendNativeToken();
    error InsufficientMsgValue();
    error InvalidAddress();
    error InvalidMessage();
    error InvalidDeliveryCost();
    error OnlySynoVaultSender();
    error OnlyWormholeTunnel();
    error Unauthorized();
    error InvalidAssetId();
    error InvalidUnderlyingToken();
    error UnderlyingTokenAlreadySet();
    error OnlyOwnerOrSynoToken();
    error InsufficientBalance();
    error InvalidRecipient();
    error AssetAlreadyExists();
    error UnderlyingTokenNotSet();
    error InvalidAsset();

    modifier onlyWormholeTunnel() {
        if (msg.sender != address(wormholeTunnel)) {
            revert OnlyWormholeTunnel();
        }
        _;
    }

    modifier onlySynoVaultSender(IWormholeTunnel.MessageSource calldata source) {
        if (source.sender != vaults[source.chainId]) {
            revert OnlySynoVaultSender();
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

    function setBaseTransferGasLimit(uint256 value) external onlyAdmin {
        baseTransferGasLimit = value;
    }

    function setContractCreationGasLimit(uint256 value) external onlyAdmin {
        contractCreationGasLimit = value;
    }

    function setSynoVault(uint16 chainId, bytes32 synoVault) external onlyAdmin {
        vaults[chainId] = synoVault;
    }

    function setDefaultFinality(IWormholeTunnel.MessageFinality value) external onlyAdmin {
        defaultFinality = value;
    }

    function getCost(uint16 targetChain, uint256 contractCallGasLimit, bool synoTokenExistsOnTargetChain) public view returns (uint256) {
        return getCost(targetChain, getGasLimit(contractCallGasLimit, synoTokenExistsOnTargetChain));
    }

    function getCost(uint16 targetChain, uint256 totalGasLimit) public view returns (uint256) {
        return wormholeTunnel.getMessageCost(targetChain, totalGasLimit, 0, false);
    }

    function getGasLimit(uint256 contractCallGasLimit, bool synoTokenExistsOnTargetChain) public view returns (uint256) {
        return baseTransferGasLimit + contractCallGasLimit + (synoTokenExistsOnTargetChain ? 0 : contractCreationGasLimit);
    }

    function receiveSynoVaultTransferMessage(
        IWormholeTunnel.MessageSource calldata source,
        IERC20,
        uint256,
        bytes calldata payload
    ) external payable onlyWormholeTunnel onlySynoVaultSender(source) {
        SynoVaultTransferMessage memory message = abi.decode(payload, (SynoVaultTransferMessage));
        if (message.asset.id == bytes32(0) || message.amount == 0 || message.recipient == bytes32(0)) revert InvalidMessage();

        // check if contract for asset exists
        AssetState storage assetState = assetStates[message.asset.id];
        if (assetState.info.id == bytes32(0)) {
            assetState.info = message.asset;
            assetState.tokenContract = new SynoToken(message.asset.name, message.asset.symbol, message.asset.decimals);
            contractToAssetId[address(assetState.tokenContract)] = message.asset.id;
        }

        address recipient = fromWormholeFormat(message.recipient);
        assetState.tokenContract.mint(recipient, message.amount);

        SynoVaultContractCall memory contractCall = abi.decode(message.encodedContractCall, (SynoVaultContractCall));
        if (contractCall.target != address(0)) {
            assetState.tokenContract.vaultApprove(recipient, contractCall.target, message.amount);
            (bool success, ) = contractCall.target.call(contractCall.payload);
            if (!success) {
                assetState.tokenContract.vaultApprove(recipient, contractCall.target, 0);
            }
        }
    }

    function transferInternal(
        uint16 targetChain,
        bytes32 assetId,
        uint256 amount,
        bytes32 recipient,
        bytes memory encodedContractCall,
        uint256 contractCallGasLimit,
        bool synoTokenExistsOnTargetChain
    ) internal {
        IWormholeTunnel.TunnelMessage memory message;

        message.source.refundRecipient = toWormholeFormat(msg.sender);
        message.source.sender = toWormholeFormat(address(this));

        message.target.chainId = targetChain;
        message.target.recipient = vaults[targetChain];
        message.target.selector = ISynoVault.receiveSynoVaultTransferMessage.selector;
        message.target.payload = abi.encode(ISynoVault.SynoVaultTransferMessage({
            asset: assetStates[assetId].info,
            amount: amount,
            recipient: recipient,
            encodedContractCall: encodedContractCall
        }));

        uint256 gasLimit = getGasLimit(contractCallGasLimit, synoTokenExistsOnTargetChain);
        uint256 cost = getCost(targetChain, gasLimit);
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

    function withdrawFromVault(address asset, uint256 amount, address recipient) external override onlyAdmin {
        if (asset == address(0)) {
            if (amount > address(this).balance) {
                amount = address(this).balance;
            }
            (bool success, ) = recipient.call{value: amount}("");
            if (!success) {
                revert FailedToSendNativeToken();
            }
        } else {
            if (underlyingTokenToAssetId[asset] != bytes32(0)) {
                // can't be an underlying token of any asset
                // TODO: what if someone sends underlying token to the vault?
                revert InvalidAsset();
            }

            IERC20 assetIERC20 = IERC20(asset);
            if (amount > assetIERC20.balanceOf(address(this))) {
                amount = assetIERC20.balanceOf(address(this));
            }
            assetIERC20.safeTransfer(recipient, amount);
        }
    }

    function transfer(address asset, uint16 targetChain, bytes32 recipient, uint256 amount, bool synoTokenExistsOnTargetChain) external payable override {
        transferAndCall(asset, targetChain, recipient, amount, SynoVaultContractCall({target: address(0), payload: bytes("")}), 0, synoTokenExistsOnTargetChain);
    }

    function transferAndCall(address asset, uint16 targetChain, bytes32 recipient, uint256 amount, SynoVaultContractCall memory contractCall, uint256 contractCallGasLimit, bool synoTokenExistsOnTargetChain) public payable override {
        if (contractToAssetId[asset] == bytes32(0)) {
            revert InvalidAssetId();
        }
        // burn the amount of the underlying token
        assetStates[contractToAssetId[asset]].tokenContract.burn(msg.sender, amount);
        transferInternal(targetChain, contractToAssetId[asset], amount, recipient, abi.encode(contractCall), contractCallGasLimit, synoTokenExistsOnTargetChain);
    }

    function addAsset(AssetInfo calldata info, address underlyingToken) external override onlyAdmin {
        if (info.id == bytes32(0)) {
            revert InvalidAssetId();
        }
        if (underlyingToken == address(0)) {
            revert InvalidUnderlyingToken();
        }
        if (underlyingTokenToAssetId[underlyingToken] != bytes32(0)) {
            revert UnderlyingTokenAlreadySet();
        }
        if (assetStates[info.id].info.id != bytes32(0)) {
            revert AssetAlreadyExists();
        }

        assetStates[info.id].info = info;
        assetStates[info.id].tokenContract = new SynoToken(info.name, info.symbol, info.decimals);
        contractToAssetId[address(assetStates[info.id].tokenContract)] = info.id;
        underlyingTokenToAssetId[underlyingToken] = info.id;
        assetStates[info.id].underlyingToken = IERC20(underlyingToken);
    }

    function setUnderlyingToken(bytes32 assetId, address underlyingToken) external override onlyAdmin {
        if (assetId == bytes32(0)) {
            revert InvalidAssetId();
        }
        if (underlyingToken == address(0)) {
            revert InvalidUnderlyingToken();
        }
        if (address(assetStates[assetId].underlyingToken) != address(0)) {
            revert UnderlyingTokenAlreadySet();
        }
        if (underlyingTokenToAssetId[underlyingToken] != bytes32(0)) {
            revert UnderlyingTokenAlreadySet();
        }
        assetStates[assetId].underlyingToken = IERC20(underlyingToken);
        underlyingTokenToAssetId[underlyingToken] = assetId;
    }

    function redeem(address asset, uint256 amount) external override {
        // asset can be either SynoToken or underlying token
        bytes32 assetId = contractToAssetId[asset];
        if (assetId == bytes32(0)) {
            assetId = underlyingTokenToAssetId[asset];
        }
        if (assetId == bytes32(0)) {
            revert InvalidAssetId();
        }

        ISynoVault.AssetState storage state = assetStates[assetId];
        if (amount > state.tokenContract.balanceOf(msg.sender)) {
            revert InsufficientBalance();
        }

        state.tokenContract.burn(msg.sender, amount);
        state.underlyingToken.safeTransfer(msg.sender, amount);
    }

    function deposit(address asset, uint256 amount) external override {
        if (underlyingTokenToAssetId[asset] == bytes32(0)) {
            revert UnderlyingTokenNotSet();
        }
        ISynoVault.AssetState storage state = assetStates[underlyingTokenToAssetId[asset]];
        state.underlyingToken.safeTransferFrom(msg.sender, address(this), amount);
        state.tokenContract.mint(msg.sender, amount);
    }

    function getSynoTokenByUnderlyingToken(address asset) external view override returns (address) {
        return address(assetStates[underlyingTokenToAssetId[asset]].tokenContract);
    }

    function getSynoTokenByAssetId(bytes32 assetId) external view override returns (address) {
        return address(assetStates[assetId].tokenContract);
    }
}
