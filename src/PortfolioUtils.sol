// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VolatilityUtils} from "src/VolatilityUtils.sol";

import {NumoToken} from "src/NumoToken.sol";
import {MathUtils} from  "src/MathUtils.sol";


/**
 * @title PortfolioUtils library
 * @notice A library to be used within Swap.sol. Contains functions responsible for custody and AMM functionalities.
 * @dev Contracts relying on this library must initialize SwapUtils.Swap struct then use this library
 * for SwapUtils.Swap struct. Note that this library contains both functions called by users and admins.
 * Admin functions should be protected within contracts using this library.
 */
library PortfolioUtils {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using MathUtilsV1 for uint256;

    /*** EVENTS ***/

    event TokenSwap(
        address indexed buyer,
        uint256 tokensSold,
        uint256 tokensBought,
        uint128 soldId,
        uint128 boughtId
    );
    event AddLiquidity(
        address indexed provider,
        uint256[] tokenAmounts,
        uint256[] fees,
        uint256 invariant,
        uint256 numoSupply
    );
    event RemoveLiquidity(
        address indexed provider,
        uint256[] tokenAmounts,
        uint256 numoSupply
    );
    event NewAdminFee(uint256 newAdminFee);
    event NewSwapFee(uint256 newSwapFee);

    struct Swap {
        address poolManager;
        // variables around the ramp management of A,
        // the voltilty factor is sigma 
        // see https://www.primitive.finance/rmm-01.pdf for details
        uint256 initialVolitlty;
        uint256 futureVolitlty;
        uint256 initialVolitltyTime;
        uint256 futureVolitltyTime;

        // fee calculation
        uint256 swapFee;
        uint256 adminFee;
        LPTokenV2 lpToken;
        // contract references for all tokens being pooled
        IERC20[] pooledTokens;
        // multipliers for each pooled token's precision to get to POOL_PRECISION_DECIMALS
        // for example, TBTC has 18 decimals, so the multiplier should be 1. WBTC
        // has 8, so the multiplier should be 10 ** 18 / 10 ** 8 => 10 ** 10
        uint256[] tokenPrecisionMultipliers;
        // the pool balance of each token, in the token's precision
        // the contract's actual token balance might differ
        uint256[] balances;

        PoolKey poolKey;
    }

    // Struct storing variables used in calculations in the
    // {add,remove}Liquidity functions to avoid stack too deep errors
    struct ManageLiquidityInfo {
        uint256 invariantInitial;
        uint256 invariantBeforeFees;
        uint256 invariantAfterFees;
        uint256 preciseVolatility;
        NumoToken numo;
        uint256 totalSupply;
        uint256[] balances;
        uint256[] multipliers;
    }

    // the precision all pools tokens will be converted to
    uint8 public constant POOL_PRECISION_DECIMALS = 18;

    // the denominator used to calculate admin and LP fees. For example, an
    // LP fee might be something like tradeAmount * (fee) / (FEE_DENOMINATOR)
    uint256 private constant FEE_DENOMINATOR = 10**10;

    // Max swap fee is 1% or 100bps of each swap
    uint256 public constant MAX_SWAP_FEE = 10**8;

    // Max adminFee is 100% of the swapFee
    // adminFee does not add additional fee on top of swapFee
    // Instead it takes a certain % of the swapFee. Therefore it has no impact on the
    // users but only on the earnings of LPs
    uint256 public constant MAX_ADMIN_FEE = 10**10;

    // Constant value used as max loop limit
    uint256 private constant MAX_LOOP_LIMIT = 256;

    /*** VIEW & PURE FUNCTIONS ***/

    function _getAPrecise(Swap storage self) internal view returns (uint256) {
        return VolatilityUtils._getAPrecise(self);
    }

    function _getSwapFee(Swap storage self) internal view returns (uint256) {
        return self.swapFee;
    }

    function _getAdminFee(Swap storage self) internal view returns (uint256) {
        return self.adminFee;
    }

    /**
     * @notice Get Delta, the RMM-01 invariant, based on a set of balances and a particular volatility.
     * @param xp a precision-adjusted set of pool balances. Array should be the same cardinality
     * as the pool.
     * @param volatility the volatility factor * n * (n - 1) in A_PRECISION.
     * See the StableSwap paper for details
     * @return the invariant, at the precision of the pool
     */
    function getDelta(uint256[] memory xp, uint256 volatility)
        internal
        pure
        returns (uint256)
    {
        uint256 numTokens = xp.length;
        uint256 s;
        for (uint256 i = 0; i < numTokens; i++) {
            s = s + xp[i];
        }
        if (s == 0) {
            return 0;
        }
        
        uint256 prevDelta;
        uint256 delta = s;
        uint256 nVolatility = volatility * numTokens;

        // Newton's method to approximate D
        // This iterative approach aims to find D that satisfies the StableSwap invariant:
        // A * n^n * sum(x_i) + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            uint256 dP = d;
            for (uint256 j = 0; j < numTokens; j++) {
                dP = (dP * d) / (xp[j] * numTokens);
            }
            prevD = d;
            // The goal is to find D that makes the following equation true:
            // D^(n+1) / (n^n * prod(x_i)) = (A * sum(x_i) + D * (n * A - 1)) / ((n * A - 1) + n)
            d = (((nA * s) / VolatilityUtils.VOLATILITY_PRECISION) + (dP * numTokens)) * d /
                ((((nA - VolatilityUtils.VOLATILITY_PRECISION) * d) / VolatilityUtils.VOLATILITY_PRECISION) + ((numTokens + 1) * dP));

            // Equality with tolerance of 1
            if (d.within1(prevD)) {
                return d;
            }
        }

        // Convergence should occur in 4 loops or less. If this is reached, there may be something wrong
        // with the pool. If this were to occur repeatedly, LPs should withdraw via `removeLiquidity()`
        // function which does not rely on D.
        revert("D does not converge");
    }

    /**
     * @notice Given a set of balances and precision multipliers, return the
     * precision-adjusted balances.
     *
     * @param balances an array of token balances, in their native precisions.
     * These should generally correspond with pooled tokens.
     *
     * @param precisionMultipliers an array of multipliers, corresponding to
     * the amounts in the balances array. When multiplied together they
     * should yield amounts at the pool's precision.
     *
     * @return an array of amounts "scaled" to the pool's precision
     */
    function _xp(
        uint256[] memory balances,
        uint256[] memory precisionMultipliers
    ) internal pure returns (uint256[] memory) {
        uint256 numTokens = balances.length;
        require(
            numTokens == precisionMultipliers.length,
            "Balances must match multipliers"
        );
        uint256[] memory xp = new uint256[](numTokens);
        for (uint256 i = 0; i < numTokens; i++) {
            xp[i] = balances[i] * precisionMultipliers[i];
        }
        return xp;
    }

    /**
     * @notice Return the precision-adjusted balances of all tokens in the pool
     * @param self Swap struct to read from
     * @return the pool balances "scaled" to the pool's precision, allowing
     * them to be more easily compared.
     */
    function _xp(Swap storage self) internal view returns (uint256[] memory) {
        return _xp(self.balances, self.tokenPrecisionMultipliers);
    }

    /**
     * @notice Calculate the new balances of the tokens given the indexes of the token
     * that is swapped from (FROM) and the token that is swapped to (TO).
     * This function is used as a helper function to calculate how much TO token
     * the user should receive on swap.
     *
     * @param preciseA precise form of amplification coefficient
     * @param tokenIndexFrom index of FROM token
     * @param tokenIndexTo index of TO token
     * @param x the new total amount of FROM token
     * @param xp balances of the tokens in the pool
     * @return the amount of TO token that should remain in the pool
     */
    function getY(
        uint256 preciseVolatility,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 x,
        uint256[] memory xp
    ) internal pure returns (uint256) {
        uint256 numTokens = xp.length;
        require(
            tokenIndexFrom != tokenIndexTo,
            "Can't compare token to itself"
        );
        require(
            tokenIndexFrom < numTokens && tokenIndexTo < numTokens,
            "Tokens must be in pool"
        );

        uint256 d = getD(xp, preciseVolatility);
        uint256 c = d;
        uint256 s;
        uint256 nVolatility = numTokens * preciseVolatility;

        uint256 _x;
        for (uint256 i = 0; i < numTokens; i++) {
            if (i == tokenIndexFrom) {
                _x = x;
            } else if (i != tokenIndexTo) {
                _x = xp[i];
            } else {
                continue;
            }
            s = s + _x;
            c = (c * d) / (_x * numTokens);
            // If we were to protect the division loss we would have to keep the denominator separate
            // and divide at the end. However this leads to overflow with large numTokens or/and D.
            // c = c * D * D * D * ... overflow!
        }
        c = (c * d * VolatilityUtils.VOLATILITY_PRECISION) / (nVolatility * numTokens);
        uint256 b = s + ((d * VolatilityUtils.VOLATILITY_PRECISION) / nVolatility);
        uint256 yPrev;
        uint256 y = d;

        // iterative approximation
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            yPrev = y;
            y = (y * y + c) / (y * 2 + b - d);
            if (y.within1(yPrev)) {
                return y;
            }
        }
        revert("Approximation did not converge");
    }

    /**
     * @notice Externally calculates a swap between two tokens.
     * @param self Swap struct to read from
     * @param tokenIndexFrom the token to sell
     * @param tokenIndexTo the token to buy
     * @param dx the number of tokens to sell. If the token charges a fee on transfers,
     * use the amount that gets transferred after the fee.
     * @return dy the number of tokens the user will get
     */
    function calculateSwap(
        Swap storage self,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx
    ) external view returns (uint256 dy) {
        (dy, ) = _calculateSwap(
            self,
            tokenIndexFrom,
            tokenIndexTo,
            dx,
            self.balances
        );
    }

    /**
     * @notice Internally calculates a swap between two tokens.
     *
     * @dev The caller is expected to transfer the actual amounts (dx and dy)
     * using the token contracts.
     *
     * @param self Swap struct to read from
     * @param tokenIndexFrom the token to sell
     * @param tokenIndexTo the token to buy
     * @param dx the number of tokens to sell. If the token charges a fee on transfers,
     * use the amount that gets transferred after the fee.
     * @return dy the number of tokens the user will get
     * @return dyFee the associated fee
     */
    function _calculateSwap(
        Swap storage self,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx,
        uint256[] memory balances
    ) internal view returns (uint256 dy, uint256 dyFee) {
        uint256[] memory multipliers = self.tokenPrecisionMultipliers;
        uint256[] memory xp = _xp(balances, multipliers);
        require(
            tokenIndexFrom < xp.length && tokenIndexTo < xp.length,
            "Token index out of range"
        );
        uint256 x = dx * multipliers[tokenIndexFrom] + xp[tokenIndexFrom];
        uint256 y = getY(
            _getAPrecise(self),
            tokenIndexFrom,
            tokenIndexTo,
            x,
            xp
        );
        dy = xp[tokenIndexTo] - y - 1;
        dyFee = (dy * self.swapFee) / FEE_DENOMINATOR;
        dy = (dy - dyFee) / multipliers[tokenIndexTo];
    }

    /**
     * @notice A simple method to calculate amount of each underlying
     * tokens that is returned upon burning given amount of
     * LP tokens
     *
     * @param amount the amount of LP tokens that would to be burned on
     * withdrawal
     * @return array of amounts of tokens user will receive
     */
    function calculateRemoveLiquidity(Swap storage self, uint256 amount)
        external
        view
        returns (uint256[] memory)
    {
        return
            _calculateRemoveLiquidity(
                self.balances,
                amount,
                self.lpToken.totalSupply()
            );
    }

    function _calculateRemoveLiquidity(
        uint256[] memory balances,
        uint256 amount,
        uint256 totalSupply
    ) internal pure returns (uint256[] memory) {
        require(amount <= totalSupply, "Cannot exceed total supply");

        uint256[] memory amounts = new uint256[](balances.length);

        for (uint256 i = 0; i < balances.length; i++) {
            amounts[i] = (balances[i] * amount) / totalSupply;
        }
        return amounts;
    }

    /**
     * @notice A simple method to calculate prices from deposits or
     * withdrawals, excluding fees but including slippage. This is
     * helpful as an input into the various "min" parameters on calls
     * to fight front-running
     *
     * @dev This shouldn't be used outside frontends for user estimates.
     *
     * @param self Swap struct to read from
     * @param amounts an array of token amounts to deposit or withdrawal,
     * corresponding to pooledTokens. The amount should be in each
     * pooled token's native precision. If a token charges a fee on transfers,
     * use the amount that gets transferred after the fee.
     * @param deposit whether this is a deposit or a withdrawal
     * @return if deposit was true, total amount of lp token that will be minted and if
     * deposit was false, total amount of lp token that will be burned
     */
    function calculateTokenAmount(
        Swap storage self,
        uint256[] calldata amounts,
        bool deposit
    ) external view returns (uint256) {
        uint256 a = _getAPrecise(self);
        uint256[] memory balances = self.balances;
        uint256[] memory multipliers = self.tokenPrecisionMultipliers;

        uint256 d0 = getD(_xp(balances, multipliers), a);
        for (uint256 i = 0; i < balances.length; i++) {
            if (deposit) {
                balances[i] = balances[i] + amounts[i];
            } else {
                if (amounts[i] > balances[i]) {
                    revert("Cannot withdraw more than available");
                } else {
                    unchecked {
                        balances[i] = balances[i] - amounts[i];
                    }
                }
            }
        }
        uint256 d1 = getD(_xp(balances, multipliers), a);
        uint256 totalSupply = self.lpToken.totalSupply();

        if (deposit) {
            return (((d1 - d0) * totalSupply) / d0);
        } else {
            return (((d0 - d1) * totalSupply) / d0);
        }
    }

    /**
     * @notice return accumulated amount of admin fees of the token with given index
     * @param self Swap struct to read from
     * @param index Index of the pooled token
     * @return admin balance in the token's precision
     */
    function getAdminBalance(Swap storage self, uint256 index)
        external
        view
        returns (uint256)
    {
        require(index < self.pooledTokens.length, "Token index out of range");
        return
            self.pooledTokens[index].balanceOf(address(this)) -
            self.balances[index];
    }

    /**
     * @notice internal helper function to calculate fee per token multiplier used in
     * swap fee calculations
     * @param swapFee swap fee for the tokens
     * @param numTokens number of tokens pooled
     */
    function _feePerToken(uint256 swapFee, uint256 numTokens)
        internal
        pure
        returns (uint256)
    {
        return ((swapFee * numTokens) / ((numTokens - 1) * 4));
    }

    /*** STATE MODIFYING FUNCTIONS ***/

    struct SwapCallbackData {
        uint256 deadline;
        uint256 minDy;
    }

    /**
     * @notice swap two tokens in the pool
     * @param self Swap struct to read from and write to
     * @param tokenIndexFrom the token the user wants to sell
     * @param tokenIndexTo the token the user wants to buy
     * @param dx the amount of tokens the user wants to sell
     * @param minDy the min amount the user would like to receive, or revert.
     * @return amount of token user received on swap
     */
    function swap(
        Swap storage self,
        IPoolManager.SwapParams calldata params,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx,
        uint256 minDy
    ) external returns (int256) {
        {
            // to do: change to univ4/6909 sette/take functionality

            // IERC20 tokenFrom = self.pooledTokens[tokenIndexFrom];
            // to do : refactor msg.sender to use callbackdata
            // require(
            //     dx <= tokenFrom.balanceOf(msg.sender),
            //     "Cannot swap more than you own"
            // );

            // to do : remove scratch work
            // // Transfer tokens first to see if a fee was charged on transfer
            // uint256 beforeBalance = tokenFrom.balanceOf(address(this));
            // tokenFrom.safeTransferFrom(msg.sender, address(this), dx);

            // // Use the actual transferred amount for AMM math
            // dx = tokenFrom.balanceOf(address(this)) - beforeBalance;
        }

        uint256 dy;
        uint256 dyFee;
        uint256[] memory balances = self.balances;
        (dy, dyFee) = _calculateSwap(
            self,
            tokenIndexFrom,
            tokenIndexTo,
            dx,
            balances
        );
        require(dy >= minDy, "Swap didn't result in min tokens");

        uint256 dyAdminFee = (((dyFee * self.adminFee) / FEE_DENOMINATOR) /
            self.tokenPrecisionMultipliers[tokenIndexTo]);

        // to do: state should be in afterswap hook?
        self.balances[tokenIndexFrom] = balances[tokenIndexFrom] + dx;
        self.balances[tokenIndexTo] = balances[tokenIndexTo] - dy - dyAdminFee;

        // to do: remove scatch work
        // self.pooledTokens[tokenIndexTo].safeTransfer(msg.sender, dy);

        if (params.zeroForOne) {
            // If user is selling Token 0 and buying Token 1

            // They will be sending Token 0 to the PM, creating a debit of Token 0 in the PM
            // We will take claim tokens for that Token 0 from the PM and keep it in the hook
            // and create an equivalent credit for that Token 0 since it is ours!
            self.poolKey.currency0.take(
                IPoolManager(self.poolManager),
                address(this),
                dx,
                true
            );

            // They will be receiving Token 1 from the PM, creating a credit of Token 1 in the PM
            // We will burn claim tokens for Token 1 from the hook so PM can pay the user
            // and create an equivalent debit for Token 1 since it is ours!
            self.poolKey.currency1.settle(
                IPoolManager(self.poolManager),
                address(this),
                dy,
                true
            );
        } else {

            self.poolKey.currency0.settle(
                IPoolManager(self.poolManager),
                address(this),
                dy,
                true
            );
            self.poolKey.currency1.take(
                IPoolManager(self.poolManager),
                address(this),
                dx,
                true
            );

        }

        emit TokenSwap(msg.sender, dx, dy, tokenIndexFrom, tokenIndexTo);

        return int256(dy);
    }

    struct LiquidityCallbackData {
        uint256 amount;
        Currency currency;
        address sender;
        address poolManager;
        bool isAdd;
    }

    /**
     * @notice Add liquidity to the pool
     * @param self Swap struct to read from and write to
     * @param amounts the amounts of each token to add, in their native precision
     * @param minToMint the minimum LP tokens adding this amount of liquidity
     * should mint, otherwise revert. Handy for front-running mitigation
     * allowed addresses. If the pool is not in the guarded launch phase, this parameter will be ignored.
     * @return amount of LP token user received
     */
    function addLiquidity(
        Swap storage self,
        uint256[] memory amounts,
        uint256 minToMint
    ) external returns (uint256) {

        // to do : remove  self.pooledTokens? as we have already modify to Uni's Currency
        //  to do : pool.checkPoolInitialized(); ?

        IERC20[] memory pooledTokens = self.pooledTokens;
        require(
            amounts.length == pooledTokens.length,
            "Amounts must match pooled tokens"
        );

        // current state
        ManageLiquidityInfo memory v = ManageLiquidityInfo(
            0,
            0,
            0,
            _getAPrecise(self),
            self.lpToken,
            0,
            self.balances,
            self.tokenPrecisionMultipliers
        );
        v.totalSupply = v.lpToken.totalSupply();

        if (v.totalSupply != 0) {
            v.d0 = getD(_xp(v.balances, v.multipliers), v.preciseA);
        }

        uint256[] memory newBalances = new uint256[](pooledTokens.length);

        for (uint256 i = 0; i < pooledTokens.length; i++) {

            // to do : check currentId if sorted? how to link with tokenIndex

            uint currentId = i == 0 ? self.poolKey.currency0.toId() : self.poolKey.currency1.toId();

            require(
                v.totalSupply != 0 || amounts[i] > 0,
                "Must supply all tokens in pool"
            );

            // Transfer tokens first to see if a fee was charged on transfer
            if (amounts[i] != 0) {
                uint256 beforeBalance = IERC6909Claims(self.poolManager).balanceOf(
                    address(this),
                    currentId
                );
                // uint256 beforeBalance = pooledTokens[i].balanceOf(
                //     address(this)
                // );

                IPoolManager(self.poolManager).unlock(
                    abi.encode(
                        LiquidityCallbackData(
                            amounts[i],
                            CurrencyLibrary.fromId(currentId),
                            msg.sender,
                            self.poolManager,
                            true
                        )
                    )
                );

                // pooledTokens[i].safeTransferFrom(
                //     msg.sender,
                //     address(this),
                //     amounts[i]
                // );

                // Update the amounts[] with actual transfer amount
                amounts[i] =
                    IERC6909Claims(self.poolManager).balanceOf(address(this), currentId) -
                    beforeBalance;
                
                // amounts[i] =
                //     pooledTokens[i].balanceOf(address(this)) -
                //     beforeBalance;
            }

            newBalances[i] = v.balances[i] + amounts[i];
        }

        // invariant after change
        v.d1 = getD(_xp(newBalances, v.multipliers), v.preciseA);
        require(v.d1 > v.d0, "D should increase");

        // updated to reflect fees and calculate the user's LP tokens
        v.d2 = v.d1;
        uint256[] memory fees = new uint256[](pooledTokens.length);

        if (v.totalSupply != 0) {
            uint256 feePerToken = _feePerToken(
                self.swapFee,
                pooledTokens.length
            );
            for (uint256 i = 0; i < pooledTokens.length; i++) {
                uint256 idealBalance = (v.d1 * v.balances[i]) / v.d0;
                fees[i] =
                    (feePerToken * idealBalance.difference(newBalances[i])) /
                    FEE_DENOMINATOR;
                self.balances[i] =
                    newBalances[i] -
                    ((fees[i] * self.adminFee) / FEE_DENOMINATOR);
                newBalances[i] = newBalances[i] - fees[i];
            }
            v.d2 = getD(_xp(newBalances, v.multipliers), v.preciseA);
        } else {
            // the initial depositor doesn't pay fees
            self.balances = newBalances;
        }

        uint256 toMint;
        if (v.totalSupply == 0) {
            toMint = v.d1;
        } else {
            toMint = ((v.d2 - v.d0) * v.totalSupply) / v.d0;
        }

        require(toMint >= minToMint, "Couldn't mint min requested");

        // mint the user's LP tokens
        v.lpToken.mint(msg.sender, toMint);

        emit AddLiquidity(
            msg.sender,
            amounts,
            fees,
            v.d1,
            v.totalSupply + toMint
        );

        return toMint;
    }

    /**
     * @notice Burn LP tokens to remove liquidity from the pool.
     * @dev Liquidity can always be removed, even when the pool is paused.
     * @param self Swap struct to read from and write to
     * @param amount the amount of LP tokens to burn
     * @param minAmounts the minimum amounts of each token in the pool
     * acceptable for this burn. Useful as a front-running mitigation
     * @return amounts of tokens the user received
     */
    function removeLiquidity(
        Swap storage self,
        uint256 amount,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory) {
        LPTokenV2 lpToken = self.lpToken;
        IERC20[] memory pooledTokens = self.pooledTokens;
        require(amount <= lpToken.balanceOf(msg.sender), ">LP.balanceOf");
        require(
            minAmounts.length == pooledTokens.length,
            "minAmounts must match poolTokens"
        );

        uint256[] memory balances = self.balances;
        uint256 totalSupply = lpToken.totalSupply();

        uint256[] memory amounts = _calculateRemoveLiquidity(
            balances,
            amount,
            totalSupply
        );

        // to do: change to univ4/6909 sette/take functionality
        for (uint256 i = 0; i < amounts.length; i++) {
            require(amounts[i] >= minAmounts[i], "amounts[i] < minAmounts[i]");
            self.balances[i] = balances[i] - amounts[i];

            uint currentId = i == 0 ? self.poolKey.currency0.toId() : self.poolKey.currency1.toId();

            // 6909 functiinality
            IPoolManager(self.poolManager).unlock(
                    abi.encode(
                        LiquidityCallbackData(
                            amounts[i],
                            CurrencyLibrary.fromId(currentId),
                            msg.sender,
                            self.poolManager,
                            false
                        )
                    )
            );
            // pooledTokens[i].safeTransfer(msg.sender, amounts[i]);

        }

        lpToken.burnFrom(msg.sender, amount);

        emit RemoveLiquidity(msg.sender, amounts, totalSupply - amount);

        return amounts;
    }

    /**
     * @notice withdraw all admin fees to a given address
     * @param self Swap struct to withdraw fees from
     * @param to Address to send the fees to
     */
    function withdrawAdminFees(Swap storage self, address to) external {
        IERC20[] memory pooledTokens = self.pooledTokens;
        for (uint256 i = 0; i < pooledTokens.length; i++) {
            IERC20 token = pooledTokens[i];
            uint256 balance = token.balanceOf(address(this)) - self.balances[i];
            if (balance != 0) {
                token.safeTransfer(to, balance);
            }
        }
    }

    /**
     * @notice Sets the admin fee
     * @dev adminFee cannot be higher than 100% of the swap fee
     * @param self Swap struct to update
     * @param newAdminFee new admin fee to be applied on future transactions
     */
    function setAdminFee(Swap storage self, uint256 newAdminFee) external {
        require(newAdminFee <= MAX_ADMIN_FEE, "Fee is too high");
        self.adminFee = newAdminFee;

        emit NewAdminFee(newAdminFee);
    }

    /**
     * @notice update the swap fee
     * @dev fee cannot be higher than 1% of each swap
     * @param self Swap struct to update
     * @param newSwapFee new swap fee to be applied on future transactions
     */
    function setSwapFee(Swap storage self, uint256 newSwapFee) external {
        require(newSwapFee <= MAX_SWAP_FEE, "Fee is too high");
        self.swapFee = newSwapFee;

        emit NewSwapFee(newSwapFee);
    }
}
