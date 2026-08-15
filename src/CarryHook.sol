// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {IRateSource} from "./interfaces/IRateSource.sol";
import {Retention} from "./lib/Retention.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

contract CarryHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using Retention for Retention.Pool;

    error PoolNotConfigured();
    error PoolAlreadyConfigured();
    error RateJumpTooLarge();

    struct YieldConfig {
        IRateSource source;
        uint24 maxFeePips;
        uint24 maxRateJumpPips;
        bool yieldIsCurrency1;
        bool configured;
    }

    mapping(PoolId => YieldConfig) public configOf;
    mapping(PoolId => uint256) public lastRateOf;

    mapping(PoolId => Retention.Pool) internal _retention;
    mapping(PoolId => mapping(bytes32 => Retention.Position)) internal _position;

    event PoolConfigured(PoolId indexed poolId, address indexed source, uint24 maxFeePips);
    event YieldRetained(PoolId indexed poolId, uint256 previousRate, uint256 newRate, uint24 feePips, uint256 amount);
    event RateUnavailable(PoolId indexed poolId);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function configurePool(
        PoolKey calldata key,
        IRateSource source,
        uint24 maxFeePips,
        uint24 maxRateJumpPips,
        bool yieldIsCurrency1
    ) external {
        PoolId id = key.toId();
        if (configOf[id].configured) revert PoolAlreadyConfigured();

        configOf[id] = YieldConfig({
            source: source,
            maxFeePips: maxFeePips,
            maxRateJumpPips: maxRateJumpPips,
            yieldIsCurrency1: yieldIsCurrency1,
            configured: true
        });
        lastRateOf[id] = source.getRate();

        emit PoolConfigured(id, address(source), maxFeePips);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        YieldConfig memory cfg = configOf[id];
        if (!cfg.configured) revert PoolNotConfigured();

        uint256 newRate;
        try cfg.source.getRate() returns (uint256 r) {
            newRate = r;
        } catch {
            emit RateUnavailable(id);
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, uint24(0) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }
        if (newRate == 0) {
            emit RateUnavailable(id);
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, uint24(0) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        uint256 previousRate = lastRateOf[id];
        if (previousRate == 0) revert PoolNotConfigured();

        // reject implausible upward jumps from a compromised or exotic rate feed
        if (newRate > previousRate && cfg.maxRateJumpPips != 0) {
            uint256 jumpPips = ((newRate - previousRate) * 1_000_000) / previousRate;
            if (jumpPips > cfg.maxRateJumpPips) revert RateJumpTooLarge();
        }
        if (newRate != previousRate) {
            lastRateOf[id] = newRate;
        }

        uint24 feePips = _gapFee(id, newRate, cfg, params.zeroForOne);

        uint256 retained = (uint256(feePips) * _abs(params.amountSpecified)) / 1_000_000;
        _retention[id].accrue(retained);

        emit YieldRetained(id, previousRate, newRate, feePips, retained);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // the fee equals the pool's current gap from par, charged only on swaps in the
    // direction that captures the gap. a dust swap cannot clear it because it cannot
    // move the pool to par, and flow in the other direction pays no surcharge.
    function _gapFee(PoolId id, uint256 rate, YieldConfig memory cfg, bool zeroForOne)
        internal
        view
        returns (uint24)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);

        // pool price of currency1 per currency0, 1e18 scale
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        uint256 poolPrice = FullMath.mulDiv(priceX96, 1e18, FixedPoint96.Q96);
        if (poolPrice == 0) return 0;

        // par price implied by the yield token's own rate
        uint256 fairPrice = cfg.yieldIsCurrency1 ? FullMath.mulDiv(1e18, 1e18, rate) : rate;
        if (fairPrice == 0) return 0;

        uint256 gapPips;
        bool arbZeroForOne;
        if (poolPrice > fairPrice) {
            // currency0 overpriced by the pool: the arb sells currency0 into it
            gapPips = ((poolPrice - fairPrice) * 1_000_000) / fairPrice;
            arbZeroForOne = true;
        } else if (poolPrice < fairPrice) {
            gapPips = ((fairPrice - poolPrice) * 1_000_000) / poolPrice;
            arbZeroForOne = false;
        }

        if (gapPips == 0 || zeroForOne != arbZeroForOne) return 0;
        return gapPips > cfg.maxFeePips ? cfg.maxFeePips : uint24(gapPips);
    }

    function currentGapFee(PoolId id, bool zeroForOne) external view returns (uint24) {
        YieldConfig memory cfg = configOf[id];
        if (!cfg.configured) revert PoolNotConfigured();
        return _gapFee(id, cfg.source.getRate(), cfg, zeroForOne);
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();
        bytes32 posKey = _positionKey(sender, params.tickLower, params.tickUpper, params.salt);
        _retention[id].addLiquidity(_position[id][posKey], uint128(uint256(params.liquidityDelta)));
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId id = key.toId();
        bytes32 posKey = _positionKey(sender, params.tickLower, params.tickUpper, params.salt);
        _retention[id].removeLiquidity(_position[id][posKey], uint128(uint256(-params.liquidityDelta)));
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function poolRetention(PoolId id)
        external
        view
        returns (uint256 accPerLiquidity, uint256 totalLiquidity, uint256 totalRetained)
    {
        Retention.Pool storage p = _retention[id];
        return (p.accPerLiquidity, p.totalLiquidity, p.totalRetained);
    }

    function pendingRetention(PoolId id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint256)
    {
        bytes32 posKey = _positionKey(owner, tickLower, tickUpper, salt);
        return _retention[id].pending(_position[id][posKey]);
    }

    function _positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tickLower, tickUpper, salt));
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
