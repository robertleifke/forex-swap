// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOption {
    function mint(address recipient, uint256 amount) external;
    function burn(address account, uint256 amount) external;
    function getParameters() external view returns (uint256, uint256, uint256, uint256);
    function getCurrentTau() external view returns (uint256);
}