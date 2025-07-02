// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

enum SynoBridgeAction {
    SUPPLY,
    WITHDRAW
}

struct SynoBridgeMessage {
    SynoBridgeAction action;
    address comet;
    address asset;
    uint256 amount;
    address recipient;
}
