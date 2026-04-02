// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

error Min();

function abs(int256 input) pure returns (uint256 output) {
    if (input == type(int256).min) revert Min();
    if (input < 0) {
        assembly {
            output := add(not(input), 1)
        }
    } else {
        assembly {
            output := input
        }
    }
}

function muli(int256 x, int256 y, int256 denominator) pure returns (int256 z) {
    assembly {
        z := mul(x, y)
        if iszero(and(iszero(iszero(denominator)), or(iszero(x), eq(sdiv(z, x), y)))) { revert(0, 0) }
        z := sdiv(z, denominator)
    }
}

function muliWad(int256 x, int256 y) pure returns (int256 z) {
    z = muli(x, y, 1 ether);
}

function diviWad(int256 x, int256 y) pure returns (int256 z) {
    z = muli(x, 1 ether, y);
}
