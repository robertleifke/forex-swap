// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title Liquidity Provider Token
 * @notice This token is an ERC20 detailed token with added capability to be minted by the owner.
 * It is used to represent user's shares when providing liquidity to swap contracts.
 * @dev Only Swap contracts should initialize and own LPToken contracts.
 */
contract NumoToken is ERC20BurnableUpgradeable, OwnableUpgradeable {
    /**
     * @notice Initializes this LPToken contract with the given name and symbol
     * @dev The caller of this function will become the owner. A Swap contract should call this
     * in its initializer function.
     * @param name name of this token
     * @param symbol symbol of this token
     */
    function initialize(string memory name, string memory symbol, address _owner)
        external
        initializer
        returns (bool)
    {
        __Context_init_unchained();
        __ERC20_init_unchained(name, symbol);
        __Ownable_init_unchained(_owner);
        return true;
    }

    /**
     * @notice Mints the given amount of LPToken to the recipient.
     * @dev only owner can call this mint function
     * @param recipient address of account to receive the tokens
     * @param amount amount of tokens to mint
     */
    function mint(address recipient, uint256 amount) external onlyOwner {
        require(amount != 0, "LPToken: cannot mint 0");
        _mint(recipient, amount);
    }

    /*///////////////////////////////////////////////////////////////
                            BEFORE TRANSFER HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Overrides ERC20._beforeTokenTransfer() which get called on every transfers including
     * minting and burning. This ensures that Swap.updateUserWithdrawFees are called everytime.
     * This assumes the owner is set to a Swap contract's address.
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);
        require(to != address(this), "LPToken: cannot send to itself");
    }

}
