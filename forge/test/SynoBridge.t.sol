// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseSynoBridgeTest } from "./BaseSynoBridge.t.sol";
import "syno-bridge-sdk/src/Utils.sol";

// tests generic non-market functions of the bridge
contract SynoBridgeTest is BaseSynoBridgeTest {
    function setUpComet() internal virtual override {
        // no comet for this test
    }

    function testWithdrawToken() public {
        uint256 amount = 100e6;
        mintUSDC(spokeFork.chainId, address(bridges[spokeFork.chainId]), amount);
        IERC20 usdc = usdcIERC20(spokeFork);
        assertEq(usdc.balanceOf(address(bridges[spokeFork.chainId])), amount, "bridge did not receive usdc");

        bridges[spokeFork.chainId].withdrawFromBridge(address(usdc), amount, USER);
        assertEq(usdc.balanceOf(USER), amount, "user did not receive usdc");
        assertEq(usdc.balanceOf(address(bridges[spokeFork.chainId])), 0, "bridge did not send usdc");
    }

    function testWithdrawNativeToken() public {
        uint256 amount = 100 ether;
        vm.deal(address(bridges[spokeFork.chainId]), amount);
        assertEq(address(bridges[spokeFork.chainId]).balance, amount, "bridge did not receive eth");

        uint256 balanceBefore = USER.balance;
        bridges[spokeFork.chainId].withdrawFromBridge(address(0), amount, USER);
        assertEq(USER.balance, balanceBefore + amount, "user did not receive eth");
        assertEq(address(bridges[spokeFork.chainId]).balance, 0, "bridge did not send eth");
    }
}
