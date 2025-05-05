// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4Router} from "lib/v4-periphery/src/V4Router.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Lock} from "./base/Lock.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title Router for Uniswap v4 swaps
contract V4SwapRouter is V4Router, Lock {
    constructor(
        IPoolManager _poolManager
    ) V4Router(_poolManager) {}

    /**
     * @notice Implementation of DeltaResolver's payment method
     * @dev Transfers tokens to the pool manager to settle negative deltas
     * @param token The token to transfer
     * @param amount The amount to transfer
     */
    function _pay(Currency token, address sender, uint256 amount) internal override {
        IERC20(Currency.unwrap(token)).transferFrom(sender, address(poolManager), amount);
    }

    /**
     * @notice Public view function to be used instead of msg.sender, as the contract performs self-reentrancy and at
     * times msg.sender == address(this). Instead msgSender() returns the initiator of the lock
     * @return The address of the initiator of the lock
     */
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    function execute(
        bytes calldata unlockData
    ) external payable isNotLocked {
        _executeActions(unlockData);
    }
}
