// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IWETH} from "@syno/interfaces/IWETH.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CometInterface } from "../../contracts/CometInterface.sol";
import { Comet } from "../../contracts/Comet.sol";
import { CometConfiguration } from "../../contracts/CometConfiguration.sol";
import { CometExt } from "../../contracts/CometExt.sol";
import { SynoBridge } from "../../contracts/bridges/SynoBridge.sol";
import { SynoVault } from "../../contracts/bridges/SynoVault.sol";
import { SynoBridgeAction } from "../../contracts/bridges/SynoBridgeStructs.sol";
import { BaseWormholeTunnelTest, ActiveFork } from "@syno/testing/BaseWormholeTunnelTest.t.sol";
import "@syno/Utils.sol";

contract SynoBridgeTest is BaseWormholeTunnelTest {
    // hub-side contracts
    CometInterface public comet;
    SynoBridge synoBridge;
    address public constant ARBITRUM_WETH9 = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant ARBITRUM_WETH_PRICE_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address public constant ARBITRUM_USDC_PRICE_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    // spoke-side contracts
    SynoVault synoVault;

    // users
    address public constant USER = address(0x1010101010101010101010101010101010101010);

    // persistent addresses
    address public COMET_ADDR;
    address public SYNO_BRIDGE_ADDR;

    function setUp() public virtual override {
        vm.recordLogs();
        super.setUp();
        switchToHub();
        synoBridge.setSynoVault(spokeFork.chainId, toWormholeFormat(address(synoVault)));
        switchToSpoke();
        synoVault.setSynoBridge(hubFork.chainId, SYNO_BRIDGE_ADDR);
    }

    function setUpFork(ActiveFork memory fork) public virtual override {
        super.setUpFork(fork);
        if (fork.chainId == hubFork.chainId) {
            setUpComet();
            synoBridge = new SynoBridge(address(this), address(tunnels[hubFork.chainId]));
            SYNO_BRIDGE_ADDR = address(synoBridge);
        } else {
            ProxyAdmin proxyAdmin = new ProxyAdmin(address(this));
            SynoVault implementation = new SynoVault();
            bytes memory initData = abi.encodeWithSelector(
                SynoVault.initialize.selector,
                hubFork.chainId,
                address(synoBridge),
                tunnels[spokeFork.chainId],
                IWETH(ARBITRUM_WETH9)
            );
            address proxy = address(new TransparentUpgradeableProxy(
                address(implementation),
                address(proxyAdmin),
                initData
            ));
            synoVault = SynoVault(payable(proxy));
        }
    }

    function setUpComet() internal {
        CometConfiguration.AssetConfig[] memory assetConfigs = new CometConfiguration.AssetConfig[](1);
        assetConfigs[0] = CometConfiguration.AssetConfig({
            asset: ARBITRUM_WETH9,
            priceFeed: ARBITRUM_WETH_PRICE_FEED,
            decimals: 18,
            borrowCollateralFactor: 9e17,
            liquidateCollateralFactor: 93e16,
            liquidationFactor: 95e16,
            supplyCap: 0
        });

        CometExt ext = new CometExt(CometConfiguration.ExtConfiguration({
            name32: keccak256("Arbitrum USDC"),
            symbol32: keccak256("USDC")
        }));

        comet = CometInterface(address(new Comet(CometConfiguration.Configuration(
            {
                governor: address(this),
                pauseGuardian: address(this),
                baseToken: address(hubFork.USDC),
                baseTokenPriceFeed: ARBITRUM_USDC_PRICE_FEED,
                extensionDelegate: address(ext),
                supplyKink: 8e17,
                supplyPerYearInterestRateSlopeLow: 3e16,
                supplyPerYearInterestRateSlopeHigh: 4e17,
                supplyPerYearInterestRateBase: 0,
                borrowKink: 8e17,
                borrowPerYearInterestRateSlopeLow: 3e16,
                borrowPerYearInterestRateSlopeHigh: 2e17,
                borrowPerYearInterestRateBase: 1e16,
                storeFrontPriceFactor: 5e17,
                trackingIndexScale: 1e15,
                baseTrackingSupplySpeed: 0,
                baseTrackingBorrowSpeed: 0,
                baseMinForRewards: 1000000e6,
                baseBorrowMin: 100e6,
                targetReserves: 5000000e6,
                assetConfigs: assetConfigs
            }
        ))));
        comet.initializeStorage();
        COMET_ADDR = address(comet);
    }

    function approveBridgeAsUser(address _user) internal {
        vm.prank(_user);
        comet.allow(address(synoBridge), true);
    }

    function testCrossChainSupply() public {
        uint256 amount = 1e6;
        switchToHub();
        approveBridgeAsUser(USER);
        switchToSpoke();
        vm.deal(USER, 1 ether);
        mintUSDC(spokeFork.chainId, USER, amount);
        switchToSpoke();
        vm.startPrank(USER);
        usdcIERC20(spokeFork).approve(address(synoVault), amount);
        uint256 cost = synoVault.getSupplyCost();
        synoVault.userActions{value: cost}(COMET_ADDR, SynoBridgeAction.SUPPLY, usdcIERC20(spokeFork), amount, 0);
        vm.stopPrank();
        deliverMessages();
        switchToHub();
        assertEq(usdcIERC20(hubFork).balanceOf(COMET_ADDR), amount, "comet did not receive usdc");
        assertEq(comet.balanceOf(USER), amount, "user not credited with base token");

    }
}
