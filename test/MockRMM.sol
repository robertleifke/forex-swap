// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "./../src/RMM.sol";

/// @dev Extends the RMM contract to expose internal functions for testing.
contract MockRMM is RMM {
    constructor(string memory name_, string memory symbol_, address PT_, uint256 sigma_, uint256 fee_)
        RMM(name_, symbol_, PT_, sigma_, fee_)
    {}

    function debit(address token, uint256 amountWad) public returns (uint256 paymentNative) {
        return _debit(token, amountWad);
    }

    function credit(address token, address to, uint256 amount) public returns (uint256 paymentNative) {
        return _credit(token, to, amount);
    }

    function adjust(int256 deltaX, int256 deltaY, int256 deltaLiquidity, uint256 strike_, PYIndex index) public {
        _adjust(deltaX, deltaY, deltaLiquidity, strike_, index);
    }

    function setLastTimestamp(uint256 lastTimestamp_) public {
        lastTimestamp = lastTimestamp_;
    }
}
