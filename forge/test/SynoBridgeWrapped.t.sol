// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IWETH} from "syno-bridge-sdk/src/interfaces/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CometInterface } from "../../contracts/CometInterface.sol";
import { Comet } from "../../contracts/Comet.sol";
import { CometConfiguration } from "../../contracts/CometConfiguration.sol";
import { CometExt } from "../../contracts/CometExt.sol";
import { BaseSynoBridgeTest } from "./BaseSynoBridge.t.sol";
import "syno-bridge-sdk/src/Utils.sol";

contract SynoBridgeWrappedTest is BaseSynoBridgeTest {

    function setUpComet() internal virtual override {
        CometConfiguration.AssetConfig[] memory assetConfigs = new CometConfiguration.AssetConfig[](1);
        assetConfigs[0] = CometConfiguration.AssetConfig({
            asset: address(hubFork.USDC),
            priceFeed: ARBITRUM_USDC_PRICE_FEED,
            decimals: 6,
            borrowCollateralFactor: 9e17,
            liquidateCollateralFactor: 93e16,
            liquidationFactor: 95e16,
            supplyCap: 1_000_000e6
        });

        CometExt ext = new CometExt(CometConfiguration.ExtConfiguration({
            name32: keccak256("Wormhole WETH"),
            symbol32: keccak256("whWETH")
        }));

        comet = CometInterface(address(new Comet(CometConfiguration.Configuration(
            {
                governor: address(this),
                pauseGuardian: address(this),
                baseToken: tunnels[hubFork.chainId].getTokenAddressOnThisChain(spokeFork.chainId, toWormholeFormat(ETHEREUM_WETH9)),
                baseTokenPriceFeed: ARBITRUM_WETH_PRICE_FEED,
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
                baseMinForRewards: 1 ether,
                baseBorrowMin: 0.1 ether,
                targetReserves: 100 ether,
                assetConfigs: assetConfigs
            }
        ))));
        comet.initializeStorage();
        COMET_ADDR = address(comet);
        vm.label(COMET_ADDR, "Comet");
    }

    // test cases

    function testCrossChainSupplyAndWithdraw() public {
        uint256 amount = 0.1 ether;
        switchToSpoke();
        IWETH weth = IWETH(ETHEREUM_WETH9);
        vm.startPrank(USER);
        weth.deposit{value: amount}();
        weth.approve(address(bridges[spokeFork.chainId]), amount);
        vm.stopPrank();
        supplyAsUser(USER, IERC20(address(weth)), amount);

        switchToHub();

        IERC20 whWeth = IERC20(tunnels[hubFork.chainId].getTokenAddressOnThisChain(spokeFork.chainId, toWormholeFormat(ETHEREUM_WETH9)));
        assertEq(whWeth.balanceOf(COMET_ADDR), amount, "comet did not receive whWeth");
        assertEq(comet.balanceOf(USER), amount, "user not credited with base token");

        // USER now has a base token balance
        // test withdrawal
        switchToSpoke();
        withdrawAsUser(USER, IERC20(address(weth)), amount);
        assertEq(weth.balanceOf(USER), amount, "user did not receive weth");
    }

    function testCrossChainBorrowAndRepay() public {
        uint256 amount = 0.1 ether;
        switchToSpoke();
        IWETH weth = IWETH(ETHEREUM_WETH9);
        vm.startPrank(USER);
        weth.deposit{value: amount}();
        weth.approve(address(bridges[spokeFork.chainId]), amount);
        vm.stopPrank();
        supplyAsUser(USER, IERC20(address(weth)), amount);

        // borrow

        address borrower = address(0x2020202020202020202020202020202020202020);
        vm.deal(borrower, 1 ether);
        switchToHub();
        uint256 collateralAmount = 1000e6;
        mintUSDC(hubFork.chainId, borrower, collateralAmount);
        IERC20 hubUsdc = usdcIERC20(hubFork);
        vm.startPrank(borrower);
        hubUsdc.approve(address(comet), collateralAmount);
        comet.allow(address(bridges[hubFork.chainId]), true);
        vm.stopPrank();
        postCollateralAsUser(borrower, hubUsdc, collateralAmount);

        switchToSpoke();
        withdrawAsUser(borrower, IERC20(address(weth)), amount);
        assertEq(weth.balanceOf(borrower), amount, "borrower did not receive weth");

        switchToHub();
        IERC20 whWeth = IERC20(tunnels[hubFork.chainId].getTokenAddressOnThisChain(spokeFork.chainId, toWormholeFormat(ETHEREUM_WETH9)));
        assertEq(whWeth.balanceOf(COMET_ADDR), 0, "comet did not send whWeth");
        assertEq(comet.borrowBalanceOf(borrower), amount, "borrower did not borrow whWeth");

        // repay
        switchToSpoke();
        supplyAsUser(borrower, IERC20(address(weth)), amount);
        switchToHub();
        assertEq(whWeth.balanceOf(COMET_ADDR), amount, "comet did not receive whWeth");
        assertEq(comet.borrowBalanceOf(borrower), 0, "borrower did not repay whWeth");
    }
}
