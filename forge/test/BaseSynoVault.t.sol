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
import { SynoVault } from "../../contracts/bridges/SynoVault.sol";
import { ISynoVault } from "../../contracts/bridges/ISynoVault.sol";
import { BaseWormholeTunnelTest, ActiveFork } from "syno-bridge-sdk/src/testing/BaseWormholeTunnelTest.t.sol";
import "syno-bridge-sdk/src/Utils.sol";

abstract contract BaseSynoVaultTest is BaseWormholeTunnelTest {
    // hub-side contracts
    CometInterface public comet;
    mapping(uint16 => ISynoVault) public vaults;
    address public constant ARBITRUM_WETH9 = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant ETHEREUM_WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant ARBITRUM_WETH_PRICE_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address public constant ARBITRUM_USDC_PRICE_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    // users
    address public constant USER = address(0x1010101010101010101010101010101010101010);

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
        vaults[hubFork.chainId].setSynoVault(spokeFork.chainId, toWormholeFormat(address(vaults[spokeFork.chainId])));
        if (address(comet) != address(0)) {
            vm.prank(USER);
            comet.allow(address(vaults[hubFork.chainId]), true);
        }
        switchToSpoke();
        vm.deal(USER, 1 ether);
        vaults[spokeFork.chainId].setSynoVault(hubFork.chainId, toWormholeFormat(address(vaults[hubFork.chainId])));
    }

    function setUpFork(ActiveFork memory fork) public virtual override {
        super.setUpFork(fork);
        address weth = fork.chainId == hubFork.chainId ? ARBITRUM_WETH9 : ETHEREUM_WETH9;
        vaults[fork.chainId] = new SynoVault(address(this), address(tunnels[fork.chainId]));
        vaults[fork.chainId].addAsset(
            ISynoVault.AssetInfo({id: keccak256("WETH"), name: "WETH", symbol: "WETH", decimals: 18}),
            weth
        );
        vaults[fork.chainId].addAsset(
            ISynoVault.AssetInfo({id: keccak256("USDC"), name: "USDC", symbol: "USDC", decimals: 6}),
            address(fork.USDC)
        );
        if (fork.chainId == hubFork.chainId) {
            setUpComet();
        }
    }

    // override this in test to set up the market
    function setUpComet() internal virtual;
}
