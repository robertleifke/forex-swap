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

import {NumoToken} from "./NumoToken.sol";
import {PortfolioUtils} from "./PortfolioUtils.sol";
import {VolatilityUtils} from "./VolatilityUtils.sol";
import {VolatilityUtils} from "./VolatilityUtils.sol";

// Define the SwapStorage struct
struct SwapStorage {
    IPoolManager poolManager;
    NumoToken numo;
    IERC20[] pooledTokens;
    uint256[] tokenPrecisionMultipliers;
    uint256[] balances;
    uint256 initialA;
    uint256 futureA;
    uint256 swapFee;
    uint256 adminFee;
    PoolKey poolKey;
}

// This contract, Portfolio, is a custom hook for Uniswap v4 pools.
// It extends BaseHook, which provides basic functionality for interacting with the Uniswap v4 core.

contract Portfolio is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    // State variable to store the decimal places of the pooled tokens
    uint8[] public decimals;

    /**
     * @notice Initializes this Swap contract with the given parameters.
     * The owner of LPToken will be this contract - which means
     * only this contract is allowed to mint/burn tokens.
     *
     * @param _poolManager reference to Uniswap v4 position manager
     * @param _pooledTokens an array of ERC20s this pool will accept
     * @param decimals the decimals to use for each pooled token,
     * eg 8 for WBTC. Cannot be larger than POOL_PRECISION_DECIMALS
     * @param _numoTokenName the long-form name of the token to be deployed
     * @param _numoTokenSymbol the short symbol for the token to be deployed
     * @param _a the amplification coefficient * n * (n - 1). See the
     * StableSwap paper for details
     * @param _fee default swap fee to be initialized with
     * @param _adminFee default adminFee to be initialized with
     */    
    /**
     * @notice Initializes this Swap contract with the given parameters.
     * The owner of LPToken will be this contract - which means
     * only this contract is allowed to mint/burn tokens.
     *
     * @param _poolManager reference to Uniswap v4 position manager
     * @param _pooledTokens an array of ERC20s this pool will accept
     * @param _decimals the decimals to use for each pooled token,
     * eg 8 for WBTC. Cannot be larger than POOL_PRECISION_DECIMALS
     * @param _numoTokenName the long-form name of the token to be deployed
     * @param _numoTokenSymbol the short symbol for the token to be deployed
     * @param _volatility the amplification coefficient * n * (n - 1). See the
     * StableSwap paper for details
     * @param _fee default swap fee to be initialized with
     * @param _adminFee default adminFee to be initialized with
     */
    constructor(
        IPoolManager _poolManager,
        IERC20[] memory _pooledTokens,
        uint8[] memory _decimals,
        string memory _numoTokenName,
        string memory _numoTokenSymbol,
        uint256 _volatility,
        uint256 _fee,
        uint256 _adminFee
    ) BaseHook(_poolManager) Ownable(msg.sender) payable {
        // todo configre Ownable's params

        // Check _pooledTokens and precisions parameter
        require(_pooledTokens.length == 2, "_pooledTokens.length == 2");

        // require(_pooledTokens.length > 1, "_pooledTokens.length <= 1");
        // require(_pooledTokens.length <= 32, "_pooledTokens.length > 32");
        require(
            _pooledTokens.length == _decimals.length,
            "_pooledTokens decimals mismatch"
        );

        // IERC20[] memory _sortedPooledTokens = new IERC20[](decimals.length);

        // address tokenA =  address(_pooledTokens[0]);
        // address tokenB =  address(_pooledTokens[1]);

        // uint8 decimalA;
        // uint8 decimalB;

        (address quote, address asset, uint8 quoteDecimal, uint8 assetDecimal)
            = address(_pooledTokens[0]) < address(_pooledTokens[1]) ?
                (address(_pooledTokens[0]), address(_pooledTokens[1]), _decimals[0], _decimals[1])
                : (address(_pooledTokens[1]), address(_pooledTokens[0]), _decimals[1], _decimals[0]);

        _pooledTokens[0] = IERC20(quote);
        _pooledTokens[1] = IERC20(asset);

        _decimals[0] = quoteDecimal;
        _decimals[1] = assetDecimal;

        uint256[] memory precisionMultipliers = new uint256[](decimals.length);

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
                decimals[i] <= PortfolioUtils.POOL_PRECISION_DECIMALS,
                "Token decimals exceeds max"
            );

            precisionMultipliers[i] =
                 10 **
                    (uint256(PortfolioUtils.POOL_PRECISION_DECIMALS) -
                        uint256(decimals[i]));

            tokenIndexes[address(_pooledTokens[i])] = i;
        }

        // Check _a, _fee, _adminFee, _withdrawFee parameters
        require(_volatility < AmplificationUtilsV2.MAX_A, "_a exceeds maximum");
        require(_fee < PortfolioUtils.MAX_SWAP_FEE, "_fee exceeds maximum");
        require(
            _adminFee < PortfolioUtils.MAX_ADMIN_FEE,
            "_adminFee exceeds maximum"
        );

        // Deploy and initialize a NumoToken contract
        NumoToken numo = new NumoToken();

        require(
            numo.initialize(_numoTokenName, _numoTokenSymbol, address(this)),
            "could not init numo clone"
        );

        // Initialize swapStorage struct
        swapStorage.poolManager = address(_poolManager);
        swapStorage.numo = numo;

        // to do : remove scatch work
        // LPTokenV2 lpToken = LPTokenV2(Clones.clone(lpTokenTargetAddress));
        // require(
        //     lpToken.initialize(_lpTokenName, _lpTokenSymbol, address(this)),
        //     "could not init lpToken clone"
        // );

        // Initialize swapStorage struct
        swapStorage.lpToken = numo;
        //to do :  sort pooledTokens
        swapStorage.pooledTokens = _pooledTokens;
        swapStorage.tokenPrecisionMultipliers = precisionMultipliers;
        swapStorage.balances = new uint256[](_pooledTokens.length);
        swapStorage.initialA = _volatility * VolatilityUtils.A_PRECISION;
        swapStorage.futureA = _volatility * VolatilityUtils.A_PRECISION;
        // swapStorage.initialATime = 0;
        // swapStorage.futureATime = 0;
        swapStorage.swapFee = _fee;
        swapStorage.adminFee = _adminFee;

        // to do : add PoolKey  key  
        // to do : initalize Uni Pool here or just store ?

        swapStorage.poolKey = PoolKey({
          currency0: Currency.wrap(quote),
          currency1: Currency.wrap(asset),
          fee: 3000,
          hooks: IHooks(address(this)),
          tickSpacing: 60
        });

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
    // Currently, it doesn't modify the swap behavior
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
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

    function getNumoToken() public view returns (NumoToken) {
        return swapStorage.numo;
    }
}
