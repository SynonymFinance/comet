// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IWormholeTunnel } from "syno-bridge-sdk/src/interfaces/IWormholeTunnel.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SynoToken } from "./SynoToken.sol";

interface ISynoVault {
    struct SynoVaultContractCall {
        address target;
        bytes payload;
    }

    struct AssetInfo {
        bytes32 id;
        string name;
        string symbol;
        uint8 decimals;
    }

    struct AssetState {
        AssetInfo info;
        SynoToken tokenContract;
        IERC20 underlyingToken;
        mapping(address => uint256) unmintedBalances;
    }

    struct SynoVaultTransferMessage {
        AssetInfo asset;
        uint256 amount;
        bytes32 recipient;
        bytes encodedContractCall;
        bool withdrawToUnderlyingToken;
    }

    function getCost(uint16 targetChain, uint256 contractCallGasLimit) external view returns (uint256);
    function getCost(uint16 targetChain, uint256 contractCallGasLimit, bool synoTokenExistsOnTargetChain) external view returns (uint256);
    function setWormholeTunnel(address wormholeTunnel_) external;
    function setSynoVault(uint16 chainId, bytes32 synoVault) external;
    function receiveSynoVaultTransferMessage(
        IWormholeTunnel.MessageSource calldata source_,
        IERC20 asset_,
        uint256 amount_,
        bytes calldata payload_
    ) external payable;
    function withdrawFromVault(address asset, uint256 amount, address recipient) external;
    function transfer(address asset, uint16 targetChain, bytes32 recipient, uint256 amount) external payable;
    function transfer(address asset, uint16 targetChain, bytes32 recipient, uint256 amount, bool synoTokenExistsOnTargetChain) external payable;
    function transfer(address asset, uint16 targetChain, bytes32 recipient, uint256 amount, bool synoTokenExistsOnTargetChain, bool withdrawToUnderlyingToken) external payable;
    function transferAndCall(address asset, uint16 targetChain, bytes32 recipient, uint256 amount, SynoVaultContractCall calldata contractCall, uint256 contractCallGasLimit) external payable;
    function transferAndCall(address asset, uint16 targetChain, bytes32 recipient, uint256 amount, SynoVaultContractCall calldata contractCall, uint256 contractCallGasLimit, bool synoTokenExistsOnTargetChain) external payable;
    function transferAndCall(address asset, uint16 targetChain, bytes32 recipient, uint256 amount, SynoVaultContractCall calldata contractCall, uint256 contractCallGasLimit, bool synoTokenExistsOnTargetChain, bool withdrawToUnderlyingToken) external payable;
    function depositAndTransfer(address asset, uint256 amount, uint16 targetChain, bytes32 recipient, SynoVaultContractCall calldata contractCall, uint256 contractCallGasLimit, bool synoTokenExistsOnTargetChain, bool withdrawToUnderlyingToken) external payable;
    function callAndTransfer(SynoVaultContractCall calldata contractCall, address asset, uint256 amount, uint16 targetChain, bytes32 recipient) external payable;
    function callAndTransfer(SynoVaultContractCall calldata contractCall, address asset, uint256 amount, uint16 targetChain, bytes32 recipient, bool synoTokenExistsOnTargetChain) external payable;
    function callAndTransfer(SynoVaultContractCall calldata contractCall, address asset, uint256 amount, uint16 targetChain, bytes32 recipient, bool synoTokenExistsOnTargetChain, bool withdrawToUnderlyingToken) external payable;
    function addAsset(AssetInfo calldata info, address underlyingToken) external;
    function setUnderlyingToken(bytes32 assetId, address underlyingToken) external;
    function redeem(address asset, uint256 amount) external;
    function deposit(address asset, uint256 amount) external;
    function getSynoTokenByUnderlyingToken(address asset) external view returns (address);
    function getSynoTokenByAssetId(bytes32 assetId) external view returns (address);
}
