// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VernierParHook} from "../src/VernierParHook.sol";
import {ERC4626RateSource} from "../src/adapters/ERC4626RateSource.sol";
import {IRateSource} from "../src/interfaces/IRateSource.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";

/// The mechanism must price accrual without becoming a fixed-price market maker.
/// These cover the two ways that goes wrong: the token trading away from par on the
/// market, and the published rate itself moving down or moving implausibly.
contract DepegTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    VernierParHook internal hook;
    MockYieldVault internal vault;
    ERC4626RateSource internal source;

    PoolKey internal parPool;
    PoolKey internal basePool;

    int24 internal constant TICK_LOWER = -6000;
    int24 internal constant TICK_UPPER = 6000;
    int256 internal constant LIQUIDITY = 100e18;
    uint256 internal constant PERIOD = 30 days;
    uint24 internal constant POOL_FEE = 500;
    uint24 internal constant MAX_APR_PIPS = 200_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        vault = new MockYieldVault();
        source = new ERC4626RateSource(address(vault));

        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VernierParHook).creationCode, abi.encode(address(manager), address(this)));
        hook = new VernierParHook{salt: salt}(IPoolManager(address(manager)), address(this));
        require(address(hook) == hookAddr, "hook mismatch");

        (parPool,) = initPool(currency0, currency1, IHooks(address(hook)), POOL_FEE, 60, SQRT_PRICE_1_1);
        (basePool,) = initPool(currency0, currency1, IHooks(address(0)), POOL_FEE, 60, SQRT_PRICE_1_1);
        _add(parPool);
        _add(basePool);

        hook.configurePool(parPool, IRateSource(address(source)), MAX_APR_PIPS, true);
    }

    /// A discount to par is real information. The hook must not paper over it.
    function test_marketDiscountStaysDiscoverable() public {
        vm.warp(block.timestamp + PERIOD);
        vault.accrue(4_000);

        uint256 priceBefore = _poolPrice();
        for (uint256 i = 0; i < 5; i++) {
            swap(parPool, false, -5e18, "");
        }
        uint256 priceAfter = _poolPrice();

        console.log("pool price before selling pressure:", priceBefore);
        console.log("pool price after selling pressure :", priceAfter);

        assertGt(priceAfter, priceBefore, "selling the yield token must cheapen it on the curve");
    }

    /// A slash the size of a year's yield is indistinguishable, in the moment, from a
    /// compromised rate source. The hook will not take a single reading's word for it, so
    /// the loss is bounded by the plausibility limit rather than eliminated outright.
    function test_slashedRate_boundsTheLossWithoutTrustingOneReading() public {
        vm.warp(block.timestamp + PERIOD);
        vault.setRate(0.95e18);
        uint256 par = vault.rate();

        // small enough that slippage does not swamp the 5% mispricing being measured
        uint256 snap = vm.snapshotState();
        int256 baseProfit = _probe(basePool, false, -0.1e18, par);
        vm.revertToState(snap);

        int256 parProfit = _probe(parPool, false, -0.1e18, par);

        console.log("selling a slashed token into the baseline pool:");
        console.logInt(baseProfit);
        console.log("selling a slashed token into the par pool    :");
        console.logInt(parProfit);

        assertLt(parProfit, baseProfit, "correction must cut the loss it can justify");
        assertGt(parProfit, 0, "and must not pretend to absorb a move it cannot verify");
    }

    /// The clamp is a rate limit, not a ceiling: successive swaps walk the accepted rate
    /// toward the reported one, so a genuine slash is fully priced in over time.
    function test_slashedRate_correctionCatchesUpOverTime() public {
        vm.warp(block.timestamp + PERIOD);
        vault.setRate(0.95e18);

        uint256 first;
        for (uint256 i = 0; i < 8; i++) {
            vm.warp(block.timestamp + PERIOD);
            swap(parPool, false, -0.1e18, "");
            if (i == 0) first = hook.lastRateOf(parPool.toId());
        }

        uint256 accepted = hook.lastRateOf(parPool.toId());

        console.log("reported rate      :", vault.rate());
        console.log("accepted after 1   :", first);
        console.log("accepted after 8   :", accepted);

        assertLt(accepted, first, "accepted rate should keep moving toward the report");
        assertApproxEqRel(accepted, vault.rate(), 0.01e18, "and should converge on it");
    }

    /// A rate source that jumps implausibly must not be able to freeze the venue.
    function test_implausibleRate_degradesInsteadOfBricking() public {
        vm.warp(block.timestamp + PERIOD);
        vault.setRate(10e18);

        swap(parPool, true, -1e18, "");
    }

    function _probe(PoolKey memory key, bool zeroForOne, int256 amount, uint256 par) internal returns (int256) {
        BalanceDelta delta = swap(key, zeroForOne, amount, "");
        return int256(delta.amount0()) + (int256(delta.amount1()) * int256(par)) / 1e18;
    }

    function _add(PoolKey memory key) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: 0}),
            ""
        );
    }

    function _poolPrice() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(parPool.toId());
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        return FullMath.mulDiv(priceX96, 1e18, FixedPoint96.Q96);
    }
}
