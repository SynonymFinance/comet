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

contract SynoBridgeCCTPTest is BaseSynoBridgeTest {

    function setUpComet() internal virtual override {
        CometConfiguration.AssetConfig[] memory assetConfigs = new CometConfiguration.AssetConfig[](1);
        assetConfigs[0] = CometConfiguration.AssetConfig({
            asset: ARBITRUM_WETH9,
            priceFeed: ARBITRUM_WETH_PRICE_FEED,
            decimals: 18,
            borrowCollateralFactor: 9e17,
            liquidateCollateralFactor: 93e16,
            liquidationFactor: 95e16,
            supplyCap: 100e18
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
        vm.label(COMET_ADDR, "Comet");
    }

    // test cases

    function testCrossChainSupply() public {
        uint256 amount = 100e6;
        switchToSpoke();
        mintUSDC(spokeFork.chainId, USER, amount);
        supplyAsUser(USER, usdcIERC20(spokeFork), amount);

        switchToHub();
        assertEq(usdcIERC20(hubFork).balanceOf(COMET_ADDR), amount, "comet did not receive usdc");
        assertEq(comet.balanceOf(USER), amount, "user not credited with base token");
    }

    function testCrossChainWithdraw() public {
        uint256 amount = 100e6;
        switchToSpoke();
        mintUSDC(spokeFork.chainId, USER, amount);
        supplyAsUser(USER, usdcIERC20(spokeFork), amount);

        assertEq(usdcIERC20(spokeFork).balanceOf(USER), 0, "user did not send usdc");

        switchToHub();
        assertEq(usdcIERC20(hubFork).balanceOf(COMET_ADDR), amount, "comet did not receive usdc");
        assertEq(comet.balanceOf(USER), amount, "user not credited with base token");

        // USER now has a base token balance
        // test withdrawal
        switchToSpoke();
        withdrawAsUser(USER, usdcIERC20(spokeFork), amount);
        assertEq(usdcIERC20(spokeFork).balanceOf(USER), amount, "user did not receive usdc");

        switchToHub();
        assertEq(usdcIERC20(hubFork).balanceOf(COMET_ADDR), 0, "comet did not send usdc");
        assertEq(comet.balanceOf(USER), 0, "user not debited with base token");
    }

    function testCrossChainBorrowAndRepay() public {
        uint256 amount = 100e6;
        switchToSpoke();
        mintUSDC(spokeFork.chainId, USER, amount);
        supplyAsUser(USER, usdcIERC20(spokeFork), amount);

        // borrow

        address borrower = address(0x2020202020202020202020202020202020202020);
        vm.deal(borrower, 1 ether);
        switchToHub();
        vm.deal(borrower, 2 ether);
        IWETH weth = IWETH(ARBITRUM_WETH9);
        vm.startPrank(borrower);
        weth.deposit{value: 1 ether}();
        comet.allow(address(bridges[hubFork.chainId]), true);
        vm.stopPrank();
        postCollateralAsUser(borrower, IERC20(address(weth)), 1 ether);

        switchToSpoke();
        withdrawAsUser(borrower, usdcIERC20(spokeFork), amount);
        assertEq(usdcIERC20(spokeFork).balanceOf(borrower), amount, "borrower did not receive usdc");

        switchToHub();
        assertEq(usdcIERC20(hubFork).balanceOf(COMET_ADDR), 0, "comet did not send usdc");
        assertEq(comet.borrowBalanceOf(borrower), amount, "borrower did not borrow usdc");

        // repay
        switchToSpoke();
        supplyAsUser(borrower, usdcIERC20(spokeFork), amount);
        switchToHub();
        assertEq(usdcIERC20(hubFork).balanceOf(COMET_ADDR), amount, "comet did not receive usdc");
        assertEq(comet.borrowBalanceOf(borrower), 0, "borrower did not repay usdc");
    }
}
