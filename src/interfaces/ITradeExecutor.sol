// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITradeExecutor {
    function executeTrade(
        address target,
        address rightsOwner,
        uint160 rechargeTarget,
        uint256 netAmount,
        bytes calldata data
    ) external;
}
