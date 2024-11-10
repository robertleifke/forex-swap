// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IMarket} from "./interfaces/IMarket.sol";

import {Option} from "./Option.sol";
import {MathUtils} from "./utils/MathUtils.sol";
import {MarketLib} from "./lib/MarketLib.sol";
import {MarketUtils} from "./utils/MarketUtils.sol";
import {VolatilityUtils} from "./utils/VolatilityUtils.sol";

// Define the SwapStorage struct
struct SwapStorage {
    IPoolManager poolManager;
    Option option;               // All option data in one place
    IERC20[] pooledTokens;      // Pool-specific data
    uint256[] tokenPrecisionMultipliers;
    uint256[] balances;
    uint256 swapFee;
    uint256 adminFee;
    uint256 volatility;
    PoolKey poolKey;
}

// Market is a custom hook implementing the RMM-01 model.
// It extends BaseHook, which provides basic functionality for interacting with the Uniswap v4 core.

contract Market is BaseHook, IMarket, Ownable {
    using PoolIdLibrary for PoolKey;

    // State variable to store the decimal places of the pooled tokens
    uint8[] public decimals;

    // State variable to store the SwapStorage struct
    SwapStorage public swapStorage;

    // Add this mapping
    mapping(address => uint8) public tokenIndexes;

    // Add missing state variables
    uint256 public strike;
    uint256 public volatility;
    uint256 public tau;
    uint256 public spotPrice;

    /**
     * @notice Initializes this pool contract with the given parameters.
     * The owner of option will be this contract - which means
     * only this contract is allowed to mint/burn tokens.
     *
     * @param _poolManager reference to Uniswap v4 position manager
     * @param _pooledTokens an array of ERC20s this pool will accept
     * @param _decimals the decimals to use for each pooled token
     * @param _optionName the long-form name of the token to be deployed
     * @param _optionSymbol the short symbol for the token to be deployed
     * @param _sigma the implied volatility of the option
     * @param _strike the strike price of the option
     * @param _tau the time to maturity of the option
     * @param _fee default swap fee to be initialized with
     * @param _adminFee default adminFee to be initialized with
     */    
    constructor(
        IPoolManager _poolManager,
        IERC20[] memory _pooledTokens,
        uint8[] memory _decimals,
        string memory _optionName,
        string memory _optionSymbol,
        uint256 _sigma,
        uint256 _strike,
        uint256 _tau,
        uint256 _fee,
        uint256 _adminFee
    ) BaseHook(_poolManager) Ownable(msg.sender) payable {
        require(_pooledTokens.length == 2, "_pooledTokens.length == 2");

        require(
            _pooledTokens.length == _decimals.length,
            "_pooledTokens decimals mismatch"
        );

        (address base, address quote, uint8 baseDecimal, uint8 quoteDecimal)
            = address(_pooledTokens[0]) < address(_pooledTokens[1]) ?
                (address(_pooledTokens[0]), address(_pooledTokens[1]), _decimals[0], _decimals[1])
                : (address(_pooledTokens[1]), address(_pooledTokens[0]), _decimals[1], _decimals[0]);

        _pooledTokens[0] = IERC20(base);
        _pooledTokens[1] = IERC20(quote);

        _decimals[0] = baseDecimal;
        _decimals[1] = quoteDecimal;

        uint256[] memory precisionMultipliers = new uint256[](_decimals.length);

        for (uint8 i = 0; i < _pooledTokens.length; i++) {
            if (i > 0) {
                // Check if index is already used. Check if 0th element is a duplicate.
                require(
                    tokenIndexes[address(_pooledTokens[i])] == 0 &&
                        _pooledTokens[0] != _pooledTokens[i],
                    "Duplicate tokens"
                );
            }
            require(
                address(_pooledTokens[i]) != address(0),
                "The 0 address isn't an ERC-20"
            );
            require(
                _decimals[i] <= MarketUtils.POOL_PRECISION_DECIMALS,
                "Token decimals exceeds max"
            );

            precisionMultipliers[i] =
                 10 **
                    (uint256(MarketUtils.POOL_PRECISION_DECIMALS) -
                        uint256(_decimals[i]));

            tokenIndexes[address(_pooledTokens[i])] = i;
        }

        // Check _a, _fee, _adminFee, _withdrawFee parameters
        require(_sigma < VolatilityUtils.MAX_VOLATILITY, "_sigma exceeds maximum");
        require(_fee < MarketUtils.MAX_SWAP_FEE, "_fee exceeds maximum");
        require(
            _adminFee < MarketUtils.MAX_ADMIN_FEE,
            "_adminFee exceeds maximum"
        );

        // Deploy and initialize an Option contract
        Option option = new Option(
            _optionName,
            _optionSymbol,
            address(this),
            _sigma,
            _strike,
            _tau,
            block.timestamp + _tau
        );

        require(
            option.initialize(_optionName, _optionSymbol, address(this)),
            "could not init option clone"
        );

        // Initialize swapStorage struct
        swapStorage.poolManager = _poolManager;
        swapStorage.option = option;
        swapStorage.pooledTokens = _pooledTokens;
        swapStorage.tokenPrecisionMultipliers = precisionMultipliers;
        swapStorage.balances = new uint256[](_pooledTokens.length);
        swapStorage.volatility = _sigma; 
        swapStorage.strike = _strike;
        swapStorage.tau = _tau;
        swapStorage.swapFee = _fee;
        swapStorage.adminFee = _adminFee;
        swapStorage.poolKey = PoolKey({
          currency0: Currency.wrap(base),
          currency1: Currency.wrap(quote),
          fee: 3000,
          hooks: IHooks(address(this)),
          tickSpacing: 60
        });

        // Store state variables
        strike = _strike;
        volatility = _sigma;
        tau = _tau;
        spotPrice = 0; // This should be updated elsewhere
    }

    // balanced liquidity in the pool, increase the amplifier ( the slippage is minimum) and the curve tries to mimic the Constant Price Model curve
    // but when the liquidity is imbalanced, decrease the amplifier  the slippage approaches infinity and the curve tries to mimic the Uniswap Constant Product Curve
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true, // Don't allow normally adding liquidity 
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // Override how swaps are done
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true, // Allow beforeSwap to return a custom delta
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Hook function called before a swap occurs
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // Get current pool state
        (uint256 base, uint256 quote) = _getCurrentReserves(key);

        // Calculate amountIn and amountOut using MarketLib
        (uint256 amountIn, uint256 amountOut) = MarketLib.computeExercise(
            !params.zeroForOne,
            uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified),
            base,
            quote,
            strike,
            volatility,
            tau,
            spotPrice
        );

        // Calculate the delta
        int256 deltaIn = !params.zeroForOne ? -int256(amountIn) : int256(amountIn);
        int256 deltaOut = !params.zeroForOne ? int256(amountOut) : -int256(amountOut);

        BeforeSwapDelta delta = BeforeSwapDelta({
            deltaIn: deltaIn,
            deltaOut: deltaOut
        });

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    // Helper function to get current reserves
    function _getCurrentReserves(PoolKey calldata key) internal view returns (uint256, uint256) {
        // Implement logic to fetch current reserves from the pool
        // This might involve calling the pool manager or reading from storage
    }

    // Hook function called after a swap occurs
    // Currently, it doesn't perform any actions post-swap
    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        return (BaseHook.afterSwap.selector, 0);
    }

    // Hook function called before liquidity is added to the pool
    // Currently, it doesn't modify the liquidity addition process
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    // Hook function called before liquidity is removed from the pool
    // Currently, it doesn't modify the liquidity removal process
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function getOption() public view returns (Option) {
        return swapStorage.option;
    }

    // function _handleExercise(ExerciseParams memory params) internal pure returns (uint256 amountIn, uint256 amountOut) {
    //     return MarketLib.computeExercise(
    //         !params.isCallExercise,
    //         params.amountSpecified,
    //         params.base,
    //         params.quote,
    //         params.strike,
    //         params.volatility,
    //         params.tau,
    //         params.spotPrice
    //     );
    // }
}

