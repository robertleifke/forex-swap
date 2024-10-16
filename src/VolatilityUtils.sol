// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PortfolioUtils} from "src/PortfolioUtils.sol";

/**
 * @title Volatility library
 * @notice A library to calculate and modify the volatility parameter of a given `PortfolioUtils.Swap` struct.
 * This library assumes the struct is fully validated.
 */
library VolatilityUtils {
    event ModifyVolatility(
        uint256 oldVolatility,
        uint256 newVolatility,
        uint256 initialTime,
        uint256 futureTime
    );
    event StopModifyVolatility(uint256 currentVolatility, uint256 time);

    // Constant values used in ramping A calculations
    uint256 public constant VOLATILITY_PRECISION = 100;
    uint256 public constant MAX_VOLATILITY = 10**6;
    uint256 private constant MAX_VOLATILITY_CHANGE = 2;
    uint256 private constant MIN_MODIFY_TIME = 14 days;

    /**
     * @notice Return volatility, the volatility factor
     * @dev See the StableSwap paper for details
     * @param self Swap struct to read from
     * @return sigma parameter
     */
    function getVolatility(PortfolioUtils.Swap storage self)
        external
        view
        returns (uint256)
    {
        return (_getVolatility(self) / VOLATILITY_PRECISION);
    }

    /**
     * @notice Return volatility in its raw precision
     * @dev See the StableSwap paper for details
     * @param self Swap struct to read from
     * @return volatility parameter in its raw precision form
     */
    function getVolatilityPrecise(PortfolioUtils.Swap storage self)
        external
        view
        returns (uint256)
    {
        return _getVolatilityPrecise(self);
    }

    /**
     * @notice Return volatility in its raw precision
     * @dev See the StableSwap paper for details
     * @param self Swap struct to read from
     * @return volatility parameter in its raw precision form
     */
    function _getVolatilityPrecise(PortfolioUtils.Swap storage self)
        internal
        view
        returns (uint256)
    {
        uint256 t1 = self.futureVolatilityTime; // time when ramp is finished
        uint256 a1 = self.futureVolatility; // final A value when ramp is finished

        if (block.timestamp < t1) {
            uint256 t0 = self.initialVolatilityTime; // time when ramp is started
            uint256 a0 = self.initialVolatility; // initial A value when ramp is started
            if (a1 > a0) {
                // a0 + (a1 - a0) * (block.timestamp - t0) / (t1 - t0)
                return a0 + (((a1 - a0) * (block.timestamp - t0)) / (t1 - t0));
            } else {
                // a0 - (a0 - a1) * (block.timestamp - t0) / (t1 - t0)
                return a0 - (((a0 - a1) * (block.timestamp - t0)) / (t1 - t0));
            }
        } else {
            return a1;
        }
    }

    /**
     * @notice Start ramping up or down A parameter towards given futureA_ and futureTime_
     * Checks if the change is too rapid, and commits the new A value only when it falls under
     * the limit range.
     * @param self Swap struct to update
     * @param futureA_ the new A to ramp towards
     * @param futureTime_ timestamp when the new A should be reached
     */
    function modifyVolatility(
        PortfolioUtils.Swap storage self,
        uint256 futureVolatility_,
        uint256 futureTime_
    ) external {
        require(
            block.timestamp >= (self.initialVolatilityTime + (1 days)),
            "Wait 1 day before starting ramp"
        );
        require(
            futureTime_ >= (block.timestamp + MIN_RAMP_TIME),
            "Insufficient ramp time"
        );
        require(
            futureVolatility_ > 0 && futureVolatility_ < MAX_VOLATILITY,
            "futureVolatility_ must be > 0 and < MAX_VOLATILITY"
        );

        uint256 initialVolatilityPrecise = _getVolatilityPrecise(self);
            uint256 futureVolatilityPrecise = futureVolatility_ * VOLATILITY_PRECISION;

        if (futureVolatilityPrecise < initialVolatilityPrecise) {
            require(
                (futureVolatilityPrecise * MAX_VOLATILITY_CHANGE) >= initialVolatilityPrecise,
                "futureVolatility_ is too small"
            );
        } else {
            require(
                futureVolatilityPrecise <= (initialVolatilityPrecise * MAX_VOLATILITY_CHANGE),
                "futureVolatility_ is too large"
            );
        }

        self.initialA = initialAPrecise;
        self.futureA = futureAPrecise;
        self.initialATime = block.timestamp;
        self.futureATime = futureTime_;

        emit ModifyVolatility(
            initialVolatilityPrecise,
            futureVolatilityPrecise,
            block.timestamp,
            futureTime_
        );
    }

    /**
     * @notice Stops modifying volatility immediately. Once this function is called, modifyVolatility()
     * cannot be called for another 24 hours
     * @param self Swap struct to update
     */
    function stopModifyVolatility(PortfolioUtils.Swap storage self) external {
        require(self.futureVolatilityTime > block.timestamp, "Modify is already stopped");

        uint256 currentVolatility = _getVolatilityPrecise(self);
        self.initialVolatility = currentVolatility;
        self.futureVolatility = currentVolatility;
        self.initialVolatilityTime = block.timestamp;
        self.futureVolatilityTime = block.timestamp;

        emit StopModifyVolatility(currentVolatility, block.timestamp);
    }
}
