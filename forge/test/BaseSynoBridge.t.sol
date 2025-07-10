// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IWETH} from "syno-bridge-sdk/src/interfaces/IWETH.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CometInterface } from "../../contracts/CometInterface.sol";
import { Comet } from "../../contracts/Comet.sol";
import { CometConfiguration } from "../../contracts/CometConfiguration.sol";
import { CometExt } from "../../contracts/CometExt.sol";
import { SynoBridge } from "../../contracts/bridges/SynoBridge.sol";
import { ISynoBridge } from "../../contracts/bridges/ISynoBridge.sol";
import { BaseWormholeTunnelTest, ActiveFork } from "syno-bridge-sdk/src/testing/BaseWormholeTunnelTest.t.sol";
import "syno-bridge-sdk/src/Utils.sol";

abstract contract BaseSynoBridgeTest is BaseWormholeTunnelTest {
    // hub-side contracts
    CometInterface public comet;
    mapping(uint16 => ISynoBridge) public bridges;
    address public constant ARBITRUM_WETH9 = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant ETHEREUM_WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant ARBITRUM_WETH_PRICE_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address public constant ARBITRUM_USDC_PRICE_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    // users
    address public constant USER = address(0x1010101010101010101010101010101010101010);

    // persistent addresses
    address public COMET_ADDR;
    address public SYNO_BRIDGE_ADDR;

    modifier retainFork() {
        uint256 forkId = vm.activeFork();
        _;
        switchToFork(forkId);
    }

    function setUp() public virtual override {
        vm.recordLogs();
        super.setUp();
        switchToHub();
        vm.deal(USER, 1 ether);
        bridges[hubFork.chainId].setSynoBridge(spokeFork.chainId, toWormholeFormat(address(bridges[spokeFork.chainId])));
        vm.prank(USER);
        comet.allow(address(bridges[hubFork.chainId]), true);
        switchToSpoke();
        vm.deal(USER, 1 ether);
        bridges[spokeFork.chainId].setSynoBridge(hubFork.chainId, toWormholeFormat(address(bridges[hubFork.chainId])));
    }

    function setUpFork(ActiveFork memory fork) public virtual override {
        super.setUpFork(fork);
        address weth = fork.chainId == hubFork.chainId ? ARBITRUM_WETH9 : ETHEREUM_WETH9;
        bridges[fork.chainId] = new SynoBridge(address(this), address(tunnels[fork.chainId]), weth);
        if (fork.chainId == hubFork.chainId) {
            setUpComet();
        }
    }

    // override this in test to set up the market
    function setUpComet() internal virtual;

    function supplyAsUser(address user_, IERC20 token_, uint256 amount_) internal retainFork {
        switchToSpoke();
        vm.startPrank(user_);
        token_.approve(address(bridges[spokeFork.chainId]), amount_);
        uint256 cost = bridges[spokeFork.chainId].getSupplyCost(hubFork.chainId);
        bridges[spokeFork.chainId].userActions{value: cost}(hubFork.chainId, COMET_ADDR, ISynoBridge.SynoBridgeAction.SUPPLY, token_, amount_, 0);
        vm.stopPrank();
        deliverMessages();
    }

    function withdrawAsUser(address user_, IERC20 token_, uint256 amount_) internal retainFork {
        switchToHub();
        uint256 returnMessageCost = bridges[hubFork.chainId].getReturnMessageCost(spokeFork.chainId);
        switchToSpoke();
        vm.startPrank(user_);
        token_.approve(address(bridges[spokeFork.chainId]), amount_);
        uint256 cost = bridges[spokeFork.chainId].getWithdrawCost(hubFork.chainId, returnMessageCost);
        bridges[spokeFork.chainId].userActions{value: cost}(hubFork.chainId, COMET_ADDR, ISynoBridge.SynoBridgeAction.WITHDRAW, token_, amount_, returnMessageCost);
        vm.stopPrank();
        deliverMessages();
        switchToHub();
        deliverMessages();
    }

    function postCollateralAsUser(address user_, IERC20 token_, uint256 amount_) internal retainFork {
        switchToHub();
        vm.startPrank(user_);
        token_.approve(address(comet), amount_);
        comet.supply(address(token_), amount_);
        vm.stopPrank();
    }
}
