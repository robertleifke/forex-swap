// SPDX-License-Identifier: LicenseRef-Gyro-1.0
// for information on licensing please see the README in the GitHub repository <https://github.com/gyrostable/core-protocol>.
pragma solidity ^0.8.4;

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/// @notice INumoToken is the NUMO token contract
interface INumoToken is IERC20Upgradeable {

    /// @notice Mints `amount` of NUMO token for `account`
    function mint(address account, uint256 amount) external;

    /// @notice Burns `amount` of NUMO token
    function burn(uint256 amount) external;

    /// @notice Burns `amount` of NUMO token from `account`
    function burnFrom(address account, uint256 amount) external;
}