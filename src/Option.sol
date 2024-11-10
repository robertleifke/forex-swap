// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title Option
 * @notice This token is an ERC20 detailed token with added capability to be minted by the owner.
 * It represents an option contract with specific parameters.
 * @dev Only authorized contracts should initialize and own Option contracts.
 */
contract Option is ERC20, Ownable {
    // Option parameters
    uint256 public sigma;    // Volatility
    uint256 public strike;   // Strike price
    uint256 public tau;      // Time to maturity
    uint256 public expiration;    // Expiration timestamp

    /*///////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event OptionMinted(address indexed recipient, uint256 amount);
    event OptionBurned(address indexed account, uint256 amount);

    /*///////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes this Option contract with the given parameters
     * @dev The caller of this function will become the owner
     * @param name name of this token
     * @param symbol symbol of this token
     * @param initialOwner address that will own this option contract
     * @param _sigma volatility parameter
     * @param _strike strike price of the option
     * @param _tau time to maturity in seconds
     * @param _expiration timestamp when option expires
     */
    constructor(
        string memory name,
        string memory symbol,
        address initialOwner,
        uint256 _sigma,
        uint256 _strike,
        uint256 _tau,
        uint256 _expiration
    ) ERC20(name, symbol) Ownable(initialOwner) {
        require(initialOwner != address(0), "Option: owner cannot be zero address");
        require(_sigma != 0, "Option: volatility cannot be zero");
        require(_strike != 0, "Option: strike price cannot be zero");
        require(_tau != 0, "Option: time to maturity cannot be zero");
        require(_expiration > block.timestamp, "Option: expiration must be in the future");
        require(_expiration == block.timestamp + _tau, "Option: expiration must match tau");
        
        sigma = _sigma;
        strike = _strike;
        tau = _tau;
        expiration = _expiration;
    }

    /**
     * @notice Mints the given amount of LPToken to the recipient.
     * @dev only owner can call this mint function
     * @param recipient address of account to receive the tokens
     * @param amount amount of tokens to mint
     */
    function mint(address recipient, uint256 amount) external onlyOwner {
        require(amount != 0, "Option: cannot mint 0");
        _mint(recipient, amount);
        emit OptionMinted(recipient, amount);
    }

    /**
     * @notice Burns the given amount of tokens from the specified account
     * @dev only owner can call this burn function
     * @param account address of account to burn tokens from
     * @param amount amount of tokens to burn
     */
    function burn(address account, uint256 amount) external onlyOwner {
        require(amount != 0, "Option: cannot burn 0");
        _burn(account, amount);
        emit OptionBurned(account, amount);
    }

    /*///////////////////////////////////////////////////////////////
                            BEFORE TRANSFER HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Prevents transfers after expiration
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        require(block.timestamp <= expiration, "OptionToken: option has expired");
        super._update(from, to, value);
        require(to != address(this), "OptionToken: cannot send to itself");
    }

    // Retrieves tau at the current timestamp
    function getCurrentTau() public view returns (uint256) {
        if (block.timestamp >= expiration) return 0;
        return expiration - block.timestamp;
    }

    // Update getParameters to use current tau
    function getParameters() external view returns (uint256, uint256, uint256, uint256) {
        return (sigma, strike, getCurrentTau(), expiration);
    }
}
