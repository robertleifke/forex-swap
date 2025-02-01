// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IStETH} from "pendle/interfaces/IStETH.sol";

contract MockStETH is MockERC20, IStETH {
    uint256 public total;

    constructor() MockERC20("stETH", "stETH", 18) {}

    function getSharesByPooledEth(uint256 _ethAmount) external view returns (uint256) {
        return _ethAmount;
    }

    function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256) {
        return _sharesAmount;
    }

    function submit(address referral) external payable returns (uint256 amount) {
        mint(msg.sender, msg.value);
        total += msg.value;
        return msg.value;
    }

    function burnShares(address _account, uint256 _sharesAmount) external returns (uint256 newTotalShares) {
        revert("not implemented");
    }

    function sharesOf(address account) external view returns (uint256) {
        revert("not implemented");
    }

    function getTotalShares() external view returns (uint256) {
        return total;
    }

    function getTotalPooledEther() external view returns (uint256) {
        return total;
    }
}
