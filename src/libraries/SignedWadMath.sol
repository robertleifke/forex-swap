// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { FullMath } from "v4-core/src/libraries/FullMath.sol";

library SignedWadMath {
    int256 internal constant WAD_INT = 1e18;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant LN_2 = 693_147_180_559_945_309;
    uint256 internal constant MAX_EXP_INPUT = 20e18;

    error Domain();

    function expWad(int256 x) internal pure returns (int256) {
        if (x == 0) return WAD_INT;
        if (x > 0) return int256(_expWad(uint256(x)));

        uint256 absX = uint256(-x);
        uint256 expAbs = _expWad(absX);
        return int256(FullMath.mulDiv(WAD, WAD, expAbs));
    }

    function lnWad(int256 x) internal pure returns (int256) {
        if (x <= 0) revert Domain();
        if (x == WAD_INT) return 0;

        bool invert = x < WAD_INT;
        uint256 y = invert ? FullMath.mulDiv(WAD, WAD, uint256(x)) : uint256(x);
        uint256 k;

        while (y >= 2 * WAD) {
            y /= 2;
            ++k;
        }

        int256 u = int256(y) - WAD_INT;
        int256 result = u;
        int256 term = u;

        for (uint256 i = 2; i <= 8; ++i) {
            term = (term * u) / WAD_INT;
            int256 contribution = term / int256(i);
            result = i % 2 == 0 ? result - contribution : result + contribution;
        }

        result += int256(k) * int256(LN_2);
        return invert ? -result : result;
    }

    function _expWad(uint256 x) private pure returns (uint256) {
        if (x == 0) return WAD;
        if (x > MAX_EXP_INPUT) return type(uint256).max / 2;

        uint256 k = x / LN_2;
        uint256 r = x % LN_2;

        uint256 series = WAD;
        uint256 term = WAD;

        for (uint256 i = 1; i <= 8; ++i) {
            term = FullMath.mulDiv(term, r, i * WAD);
            series += term;
        }

        return series << k;
    }
}
