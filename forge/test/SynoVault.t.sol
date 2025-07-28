// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseSynoVaultTest } from "./BaseSynoVault.t.sol";
import "syno-bridge-sdk/src/Utils.sol";

// tests generic non-market functions of the bridge
contract SynoVaultTest is BaseSynoVaultTest {
    function setUpComet() internal virtual override {
        // no comet for this test
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

        // let's now mint some hub-side USDC to the vault so that the user can redeem it
        mintUSDC(hubFork.chainId, address(vaults[hubFork.chainId]), amount);
        vm.prank(USER);
        vaults[hubFork.chainId].redeem(address(hubSynoUsdc), amount);
        assertEq(hubSynoUsdc.balanceOf(USER), 0, "user did not redeem hub syno usdc");
        assertEq(hubFork.USDC.balanceOf(USER), amount, "user did not receive usdc");
        assertEq(hubFork.USDC.balanceOf(address(vaults[hubFork.chainId])), 0, "vault did not receive usdc");
        assertEq(hubSynoUsdc.balanceOf(USER), 0, "user did not redeem hub syno usdc");
        assertEq(hubSynoUsdc.totalSupply(), 0, "hub syno usdc total supply is not correct");
    }
}
