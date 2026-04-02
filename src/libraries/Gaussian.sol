// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SignedWadMath} from "./SignedWadMath.sol";
import {diviWad, muliWad} from "./Units.sol";

/**
 * @notice Canonical normal CDF/PPF helpers backed by a single inverse-normal approximation family.
 * @dev `ppf` uses Peter J. Acklam's rational approximation. `cdf` is defined by binary search over `ppf`,
 * which keeps closure stable because both directions come from the same monotone representation.
 */
library Gaussian {
    error Infinity();
    error NegativeInfinity();
    error OutOfBounds();

    int256 internal constant WAD = 1 ether;
    int256 internal constant HALF_WAD = 0.5 ether;
    int256 internal constant ONE = 1 ether;
    int256 internal constant TWO = 2 ether;
    int256 internal constant SQRT_2PI = 2_506628274631000502;

    int256 internal constant P_LOW = 24_250_000_000_000_000;
    int256 internal constant P_HIGH = 975_750_000_000_000_000;
    int256 internal constant CDF_EPS = 1;
    uint256 internal constant CDF_STEPS = 64;

    int256 internal constant A1 = -39_696_830_286_653_760_000;
    int256 internal constant A2 = 220_946_098_424_520_500_000;
    int256 internal constant A3 = -275_928_510_446_968_700_000;
    int256 internal constant A4 = 138_357_751_867_269_000_000;
    int256 internal constant A5 = -30_664_798_066_147_160_000;
    int256 internal constant A6 = 2_506_628_277_459_239_000;

    int256 internal constant B1 = -54_476_098_798_224_060_000;
    int256 internal constant B2 = 161_585_836_858_040_900_000;
    int256 internal constant B3 = -155_698_979_859_886_600_000;
    int256 internal constant B4 = 66_801_311_887_719_720_000;
    int256 internal constant B5 = -13_280_681_552_885_720_000;

    int256 internal constant C1 = -7_784_894_002_430_293;
    int256 internal constant C2 = -322_396_458_041_136_500;
    int256 internal constant C3 = -2_400_758_277_161_838_000;
    int256 internal constant C4 = -2_549_732_539_343_734_000;
    int256 internal constant C5 = 4_374_664_141_464_968_000;
    int256 internal constant C6 = 2_938_163_982_698_783_000;

    int256 internal constant D1 = 7_784_695_709_041_462;
    int256 internal constant D2 = 322_467_129_070_039_800;
    int256 internal constant D3 = 2_445_134_137_142_996_000;
    int256 internal constant D4 = 3_754_408_661_907_416_000;

    function cdf(int256 x) internal pure returns (int256 z) {
        int256 low = CDF_EPS;
        int256 high = ONE - CDF_EPS;

        for (uint256 i = 0; i < CDF_STEPS; ++i) {
            int256 mid = (low + high) / 2;
            int256 guess = ppf(mid);
            if (guess < x) low = mid + 1;
            else high = mid;
        }

        z = high;
    }

    function pdf(int256 x) internal pure returns (int256 z) {
        int256 e = (-(x * x)) / TWO;
        e = SignedWadMath.expWad(e);
        z = (e * ONE) / SQRT_2PI;
    }

    function ppf(int256 x) internal pure returns (int256 z) {
        if (x <= 0) revert NegativeInfinity();
        if (x >= ONE) revert Infinity();
        if (x == HALF_WAD) return 0;

        if (x < P_LOW) {
            int256 tailQ = _sqrtWad(-muliWad(TWO, SignedWadMath.lnWad(x)));
            return _tailApprox(tailQ);
        }

        if (x > P_HIGH) {
            int256 tailQ = _sqrtWad(-muliWad(TWO, SignedWadMath.lnWad(ONE - x)));
            return -_tailApprox(tailQ);
        }

        int256 q = x - HALF_WAD;
        int256 r = muliWad(q, q);

        int256 num = muliWad(A1, r) + A2;
        num = muliWad(num, r) + A3;
        num = muliWad(num, r) + A4;
        num = muliWad(num, r) + A5;
        num = muliWad(num, r) + A6;

        int256 den = muliWad(B1, r) + B2;
        den = muliWad(den, r) + B3;
        den = muliWad(den, r) + B4;
        den = muliWad(den, r) + B5;
        den = muliWad(den, r) + ONE;

        z = muliWad(diviWad(num, den), q);
    }

    function _tailApprox(int256 q) private pure returns (int256 z) {
        int256 num = muliWad(C1, q) + C2;
        num = muliWad(num, q) + C3;
        num = muliWad(num, q) + C4;
        num = muliWad(num, q) + C5;
        num = muliWad(num, q) + C6;

        int256 den = muliWad(D1, q) + D2;
        den = muliWad(den, q) + D3;
        den = muliWad(den, q) + D4;
        den = muliWad(den, q) + ONE;
        z = diviWad(num, den);
    }

    function _sqrtWad(int256 x) private pure returns (int256 z) {
        if (x < 0) revert OutOfBounds();
        if (x == 0) return 0;
        z = int256(_sqrt(uint256(x) * uint256(WAD)));
    }

    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }
}
