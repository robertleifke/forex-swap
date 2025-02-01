// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {MockERC20, ERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IWstETH} from "pendle/interfaces/IWstETH.sol";

contract MockWstETH is MockERC20, IWstETH {
    address public stETH;

    constructor(address stETH_) MockERC20("wstETH", "wstETH", 18) {
        stETH = stETH_;
    }

    function wrap(uint256 _stETHAmount) external returns (uint256) {
        ERC20(stETH).transferFrom(msg.sender, address(this), _stETHAmount);
        return _stETHAmount;
    }

    function unwrap(uint256 _wstETHAmount) external returns (uint256) {
        ERC20(stETH).transfer(msg.sender, _wstETHAmount);
        return _wstETHAmount;
    }

    function stEthPerToken() external pure returns (uint256) {
        return 1 ether;
    }
}
