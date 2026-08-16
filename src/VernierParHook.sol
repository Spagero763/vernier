// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {IRateSource} from "./interfaces/IRateSource.sol";
import {Retention} from "./lib/Retention.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// Prices the curve's staleness instead of taxing the arbitrage that corrects it.
///
/// A yield token's share appreciates by a factor the token itself publishes, so the
/// curve's quoted price goes stale by exactly that factor and nothing else. This hook
/// applies the factor as a multiplicative correction on the leg the swapper does not
/// specify, which leaves genuine market deviation from par on the curve where it can
/// still be discovered and arbitraged.
contract VernierParHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using Retention for Retention.Pool;

    error PoolNotConfigured();
    error PoolAlreadyConfigured();
    error RateJumpTooLarge();
    error NotOwner();

    struct YieldConfig {
        IRateSource source;
        uint256 referenceRate;
        uint64 lastRateAt;
        uint24 maxRateAprPips;
        bool yieldIsCurrency1;
        bool configured;
    }

    uint256 internal constant ONE = 1e18;
    uint256 internal constant YEAR = 365 days;

    address public immutable owner;

    /// v4 reports the caller of modifyLiquidity, which for any periphery router is the
    /// router itself. Routers listed here may name the real position owner in hookData;
    /// anyone else is taken at face value.
    mapping(address => bool) public trustedRouter;

    mapping(PoolId => YieldConfig) public configOf;
    mapping(PoolId => uint256) public lastRateOf;

    mapping(PoolId => Retention.Pool) internal _retained0;
    mapping(PoolId => Retention.Pool) internal _retained1;
    mapping(PoolId => mapping(bytes32 => Retention.Position)) internal _position0;
    mapping(PoolId => mapping(bytes32 => Retention.Position)) internal _position1;

    event PoolConfigured(PoolId indexed poolId, address indexed source, uint256 referenceRate);
    event StalenessPriced(PoolId indexed poolId, uint256 rate, uint256 multiplier, uint256 corrected);
    event RateUnavailable(PoolId indexed poolId);
    event Claimed(PoolId indexed poolId, address indexed lp, uint256 amount0, uint256 amount1);
    event TrustedRouterSet(address indexed router, bool trusted);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setTrustedRouter(address router, bool trusted) external onlyOwner {
        trustedRouter[router] = trusted;
        emit TrustedRouterSet(router, trusted);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// Curated by design: an unconfigured pool reverts every swap, so leaving this open
    /// would let anyone brick a pool or pin it to a hostile rate source permanently.
    function configurePool(PoolKey calldata key, IRateSource source, uint24 maxRateAprPips, bool yieldIsCurrency1)
        external
        onlyOwner
    {
        PoolId id = key.toId();
        if (configOf[id].configured) revert PoolAlreadyConfigured();

        uint256 rate = source.getRate();
        configOf[id] = YieldConfig({
            source: source,
            referenceRate: rate,
            lastRateAt: uint64(block.timestamp),
            maxRateAprPips: maxRateAprPips,
            yieldIsCurrency1: yieldIsCurrency1,
            configured: true
        });
        lastRateOf[id] = rate;

        emit PoolConfigured(id, address(source), rate);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        YieldConfig memory cfg = configOf[id];
        if (!cfg.configured) revert PoolNotConfigured();

        uint256 rate = _readRate(id, cfg);
        if (rate == 0) return (IHooks.afterSwap.selector, int128(0));

        _guardRate(id, cfg, rate);

        // the swapper only captures staleness when taking the yield token off the curve
        if (params.zeroForOne != cfg.yieldIsCurrency1) return (IHooks.afterSwap.selector, int128(0));

        uint256 multiplier = FullMath.mulDiv(rate, ONE, cfg.referenceRate);
        if (multiplier <= ONE) return (IHooks.afterSwap.selector, int128(0));

        (uint256 correction, Currency unspecified) = _correction(key, cfg, params, delta, multiplier);
        if (correction == 0) return (IHooks.afterSwap.selector, int128(0));

        poolManager.take(unspecified, address(this), correction);

        if (Currency.unwrap(unspecified) == Currency.unwrap(key.currency0)) {
            _retained0[id].accrue(correction);
        } else {
            _retained1[id].accrue(correction);
        }

        emit StalenessPriced(id, rate, multiplier, correction);

        return (IHooks.afterSwap.selector, int128(uint128(correction)));
    }

    function _readRate(PoolId id, YieldConfig memory cfg) internal returns (uint256) {
        try cfg.source.getRate() returns (uint256 r) {
            if (r == 0) emit RateUnavailable(id);
            return r;
        } catch {
            emit RateUnavailable(id);
            return 0;
        }
    }

    function _correction(
        PoolKey calldata key,
        YieldConfig memory cfg,
        SwapParams calldata params,
        BalanceDelta delta,
        uint256 multiplier
    ) internal pure returns (uint256, Currency) {
        if (params.amountSpecified < 0) {
            // unspecified leg is the yield output: hand back only what par supports
            int128 yieldLeg = cfg.yieldIsCurrency1 ? delta.amount1() : delta.amount0();
            if (yieldLeg <= 0) return (0, key.currency0);
            return (
                FullMath.mulDiv(uint256(uint128(yieldLeg)), multiplier - ONE, multiplier),
                cfg.yieldIsCurrency1 ? key.currency1 : key.currency0
            );
        }

        // unspecified leg is the quote input: charge what par actually costs
        int128 quoteLeg = cfg.yieldIsCurrency1 ? delta.amount0() : delta.amount1();
        if (quoteLeg >= 0) return (0, key.currency0);
        return (
            FullMath.mulDiv(uint256(uint128(-quoteLeg)), multiplier - ONE, ONE),
            cfg.yieldIsCurrency1 ? key.currency0 : key.currency1
        );
    }

    /// Bounds the rate by implied APR rather than per-swap step, so a sequence of
    /// small moves cannot ratchet the reference the way a step bound allows.
    function _guardRate(PoolId id, YieldConfig memory cfg, uint256 rate) internal {
        uint256 previous = lastRateOf[id];
        if (previous == 0) revert PoolNotConfigured();
        if (rate == previous) return;

        if (cfg.maxRateAprPips != 0) {
            uint256 elapsed = block.timestamp - cfg.lastRateAt;
            if (elapsed == 0) elapsed = 1;

            uint256 change = rate > previous ? rate - previous : previous - rate;
            uint256 impliedApr = FullMath.mulDiv(change, 1_000_000 * YEAR, previous * elapsed);
            if (impliedApr > cfg.maxRateAprPips) revert RateJumpTooLarge();
        }

        lastRateOf[id] = rate;
        configOf[id].lastRateAt = uint64(block.timestamp);
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();
        bytes32 posKey =
            _positionKey(_positionOwner(sender, hookData), params.tickLower, params.tickUpper, params.salt);
        uint128 amount = uint128(uint256(params.liquidityDelta));
        _retained0[id].addLiquidity(_position0[id][posKey], amount);
        _retained1[id].addLiquidity(_position1[id][posKey], amount);
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        PoolId id = key.toId();
        bytes32 posKey =
            _positionKey(_positionOwner(sender, hookData), params.tickLower, params.tickUpper, params.salt);
        uint128 amount = uint128(uint256(-params.liquidityDelta));
        _retained0[id].removeLiquidity(_position0[id][posKey], amount);
        _retained1[id].removeLiquidity(_position1[id][posKey], amount);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function claim(PoolKey calldata key, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId id = key.toId();
        bytes32 posKey = _positionKey(msg.sender, tickLower, tickUpper, salt);

        Retention.Position storage p0 = _position0[id][posKey];
        Retention.Position storage p1 = _position1[id][posKey];

        _retained0[id].settle(p0);
        _retained1[id].settle(p1);

        amount0 = p0.accrued;
        amount1 = p1.accrued;
        p0.accrued = 0;
        p1.accrued = 0;

        if (amount0 > 0) key.currency0.transfer(msg.sender, amount0);
        if (amount1 > 0) key.currency1.transfer(msg.sender, amount1);

        emit Claimed(id, msg.sender, amount0, amount1);
    }

    function _positionOwner(address sender, bytes calldata hookData) internal view returns (address) {
        if (hookData.length == 32 && trustedRouter[sender]) return abi.decode(hookData, (address));
        return sender;
    }

    function poolRetention(PoolId id) external view returns (uint256 retained0, uint256 retained1) {
        return (_retained0[id].totalRetained, _retained1[id].totalRetained);
    }

    function pendingRetention(PoolId id, address lp, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 posKey = _positionKey(lp, tickLower, tickUpper, salt);
        return (_retained0[id].pending(_position0[id][posKey]), _retained1[id].pending(_position1[id][posKey]));
    }

    function _positionKey(address lp, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(lp, tickLower, tickUpper, salt));
    }
}
