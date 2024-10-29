// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IMarket {
    struct ExerciseParams {
        bool isCallExercise;
        int256 amountSpecified;
        uint256 base;
        uint256 quote;
        uint256 strike;
        uint256 volatility;
        uint256 tau;
        uint256 spotPrice;
    }
}