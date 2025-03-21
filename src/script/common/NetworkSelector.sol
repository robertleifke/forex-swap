// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "./INetwork.sol";
import "../mainnet/Mainnet.sol";
import "../local/Local.sol";

contract NetworkSelector {
    enum Networks {
        MAINNET, // 0
        LOCAL // 1

    }

    function stringToNetwork(
        string memory network
    ) public pure returns (Networks) {
        bytes32 hashedInput = keccak256(abi.encodePacked(network));

        if (hashedInput == keccak256(abi.encodePacked("MAINNET"))) {
            return Networks.MAINNET;
        } else if (hashedInput == keccak256(abi.encodePacked("LOCAL"))) {
            return Networks.LOCAL;
        } else {
            revert("NetworkSelector: invalid network string");
        }
    }

    function select(
        string calldata envNetwork
    ) external returns (INetwork) {
        Networks network = stringToNetwork(envNetwork);

        if (network == Networks.MAINNET) {
            return new Mainnet();
        } else if (network == Networks.LOCAL) {
            return new Local();
        } else {
            revert("NetworkSelector: invalid network");
        }
    }
}