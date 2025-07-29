// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CometInterface } from "../../contracts/CometInterface.sol";
import { Comet } from "../../contracts/Comet.sol";
import { CometConfiguration } from "../../contracts/CometConfiguration.sol";
import { CometExt } from "../../contracts/CometExt.sol";
import { BaseSynoVaultTest } from "./BaseSynoVault.t.sol";
import { ISynoVault } from "../../contracts/bridges/ISynoVault.sol";
import "syno-bridge-sdk/src/Utils.sol";

// tests generic non-market functions of the bridge
contract SynoVaultTest is BaseSynoVaultTest {
    address public COMET_ADDR;
    bytes32 public constant USDC_ASSET_ID = keccak256("USDC");

    address public constant MARKET_MAKER = address(0x2020202020202020202020202020202020202020);


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

    function setUp() public override {
        super.setUp();
        uint256 mmAmount = 10_000e6;

        switchToSpoke();
        mintUSDC(spokeFork.chainId, MARKET_MAKER, mmAmount);
        vm.startPrank(MARKET_MAKER);
        spokeFork.USDC.approve(address(vaults[spokeFork.chainId]), mmAmount);
        vaults[spokeFork.chainId].deposit(address(spokeFork.USDC), mmAmount);
        vm.stopPrank();

        switchToHub();
        mintUSDC(hubFork.chainId, MARKET_MAKER, mmAmount);
        vm.startPrank(MARKET_MAKER);
        hubFork.USDC.approve(address(vaults[hubFork.chainId]), mmAmount);
        vaults[hubFork.chainId].deposit(address(hubFork.USDC), mmAmount);
        vm.stopPrank();

        vm.prank(USER);
        comet.allow(address(vaults[hubFork.chainId]), true);
    }

    function testDepositRedeemToken() public {
        uint256 amount = 100e6;
        mintUSDC(spokeFork.chainId, USER, amount);
        IERC20 usdc = usdcIERC20(spokeFork);

        vm.startPrank(USER);
        usdc.approve(address(vaults[spokeFork.chainId]), amount);
        vaults[spokeFork.chainId].deposit(address(usdc), amount);
        vm.stopPrank();
        IERC20 synoUsdc = IERC20(vaults[spokeFork.chainId].getSynoTokenByUnderlyingToken(address(usdc)));
        assertEq(synoUsdc.balanceOf(USER), amount, "user did not receive syno usdc");
        assertEq(synoUsdc.totalSupply(), amount, "syno usdc total supply is not correct");
        assertEq(usdc.balanceOf(address(vaults[spokeFork.chainId])), amount, "vault did not receive usdc");

        vm.prank(USER);
        vaults[spokeFork.chainId].redeem(address(synoUsdc), amount);
        assertEq(synoUsdc.balanceOf(USER), 0, "user did not redeem syno usdc");
        assertEq(synoUsdc.totalSupply(), 0, "syno usdc total supply is not correct");
        assertEq(usdc.balanceOf(address(vaults[spokeFork.chainId])), 0, "vault did not receive usdc");
        assertEq(usdc.balanceOf(USER), amount, "user did not receive usdc");
    }

    function testCrossChainAssetTransfer() public {
        uint256 amount = 100e6;
        mintUSDC(spokeFork.chainId, USER, amount);
        IERC20 usdc = usdcIERC20(spokeFork);

        vm.startPrank(USER);
        usdc.approve(address(vaults[spokeFork.chainId]), amount);
        vaults[spokeFork.chainId].deposit(address(usdc), amount);
        IERC20 synoUsdc = IERC20(vaults[spokeFork.chainId].getSynoTokenByUnderlyingToken(address(usdc)));
        uint256 cost = vaults[spokeFork.chainId].getCost(hubFork.chainId, 0, false);
        vaults[spokeFork.chainId].transfer{value: cost}(
            address(synoUsdc),
            hubFork.chainId,
            toWormholeFormat(USER),
            amount,
            false // other SynoToken exists on target chain
        );
        vm.stopPrank();
        // assert USDC still in vault
        assertEq(usdc.balanceOf(address(vaults[spokeFork.chainId])), amount, "vault did not receive usdc");
        // assert spoke-side synoUsdc is burned
        assertEq(synoUsdc.balanceOf(USER), 0, "synoUsdc is not burned");
        assertEq(synoUsdc.totalSupply(), 0, "synoUsdc total supply is not correct");
        deliverMessages();

        switchToHub();
        IERC20 hubSynoUsdc = IERC20(vaults[hubFork.chainId].getSynoTokenByUnderlyingToken(address(hubFork.USDC)));
        assertEq(hubSynoUsdc.balanceOf(USER), amount, "user did not receive hub syno usdc");
        assertEq(hubSynoUsdc.totalSupply(), amount, "hub syno usdc total supply is not correct");

        vm.prank(USER);
        vaults[hubFork.chainId].redeem(address(hubSynoUsdc), amount);
        assertEq(hubSynoUsdc.balanceOf(USER), 0, "user did not redeem hub syno usdc");
        assertEq(hubFork.USDC.balanceOf(USER), amount, "user did not receive usdc");
        assertEq(hubFork.USDC.balanceOf(address(vaults[hubFork.chainId])), 0, "vault did not receive usdc");
        assertEq(hubSynoUsdc.balanceOf(USER), 0, "user did not redeem hub syno usdc");
        assertEq(hubSynoUsdc.totalSupply(), 0, "hub syno usdc total supply is not correct");
    }

    function testSynoVaultSupplyAndWithdraw() public {
        switchToSpoke();

        uint256 amount = 100e6;
        mintUSDC(spokeFork.chainId, USER, amount);

        uint256 cometSupplyGasLimit = 200_000;
        uint256 supplyCost = vaults[spokeFork.chainId].getCost(hubFork.chainId, cometSupplyGasLimit, true);
        ISynoVault.SynoVaultContractCall memory supplyCall = ISynoVault.SynoVaultContractCall({
            target: COMET_ADDR,
            payload: abi.encodeWithSelector(Comet.supplyTo.selector, USER, address(hubFork.USDC), amount)
        });

        vm.startPrank(USER);
        spokeFork.USDC.approve(address(vaults[spokeFork.chainId]), amount);
        vaults[spokeFork.chainId].deposit(address(spokeFork.USDC), amount);
        IERC20 synoSpokeUsdc = IERC20(vaults[spokeFork.chainId].getSynoTokenByUnderlyingToken(address(spokeFork.USDC)));
        vaults[spokeFork.chainId].transferAndCall{value:supplyCost}(
            address(synoSpokeUsdc),
            hubFork.chainId,
            toWormholeFormat(USER),
            amount,
            supplyCall,
            cometSupplyGasLimit,
            true, // syno token exists on target chain
            true // withdraw to underlying token before calling comet
        );
        vm.stopPrank();
        deliverMessages();

        switchToHub();
        assertEq(comet.balanceOf(USER), amount, "user did not receive syno usdc");

        ISynoVault.SynoVaultContractCall memory withdrawCall = ISynoVault.SynoVaultContractCall({
            target: COMET_ADDR,
            payload: abi.encodeWithSelector(Comet.withdrawFrom.selector, USER, address(vaults[hubFork.chainId]), address(hubFork.USDC), amount)
        });
        uint256 withdrawCost = vaults[hubFork.chainId].getCost(spokeFork.chainId, 0, true);
        vm.startPrank(USER);
        vaults[hubFork.chainId].callAndTransfer{value:withdrawCost}(
            withdrawCall,
            address(hubFork.USDC),
            amount,
            spokeFork.chainId,
            toWormholeFormat(USER),
            true, // SynoToken exists on target chain
            true // withdraw to underlying token (Spoke-side USDC)
        );
        vm.stopPrank();
        deliverMessages();

        switchToSpoke();
        assertEq(spokeFork.USDC.balanceOf(USER), amount, "user did not receive usdc");
    }
}
