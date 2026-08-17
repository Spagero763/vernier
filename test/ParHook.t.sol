// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VernierParHook} from "../src/VernierParHook.sol";
import {ERC4626RateSource} from "../src/adapters/ERC4626RateSource.sol";
import {IRateSource} from "../src/interfaces/IRateSource.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";

contract ParHookTest is Test, Deployers {
    VernierParHook internal hook;
    MockYieldVault internal vault;
    ERC4626RateSource internal source;

    PoolKey internal basePool;
    PoolKey internal parPool;

    int24 internal constant TICK_LOWER = -6000;
    int24 internal constant TICK_UPPER = 6000;
    int256 internal constant LIQUIDITY = 100e18;

    uint16 internal constant PERIODS = 12;
    uint256 internal constant PERIOD = 30 days;
    uint256 internal constant ACCRUAL_PIPS = 4_000;
    uint24 internal constant POOL_FEE = 500;
    uint24 internal constant MAX_APR_PIPS = 200_000;

    int256[8] internal SIZES = [int256(0.01e18), 0.05e18, 0.1e18, 0.25e18, 0.5e18, 1e18, 2e18, 5e18];

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

        (basePool,) = initPool(currency0, currency1, IHooks(address(0)), POOL_FEE, 60, SQRT_PRICE_1_1);
        (parPool,) = initPool(currency0, currency1, IHooks(address(hook)), POOL_FEE, 60, SQRT_PRICE_1_1);

        _add(basePool, LIQUIDITY);
        _add(parPool, LIQUIDITY);

        hook.configurePool(parPool, IRateSource(address(source)), MAX_APR_PIPS, true);
    }

    function test_parHook_deniesAccrualArbitrage() public {
        int256 baseExtracted;
        int256 parExtracted;

        for (uint16 i = 0; i < PERIODS; i++) {
            vm.warp(block.timestamp + PERIOD);
            vault.accrue(ACCRUAL_PIPS);
            uint256 par = vault.rate();

            baseExtracted += _runArb(basePool, par);
            parExtracted += _runArb(parPool, par);
        }

        console.log("value extracted from baseline:");
        console.logInt(baseExtracted);
        console.log("value extracted from par pool:");
        console.logInt(parExtracted);

        assertGt(baseExtracted, 0, "baseline leaks accrual to arbitrage");
        assertLt(parExtracted, baseExtracted / 10, "par pool should leak an order of magnitude less");
    }

    /// Retail buying a stale-cheap yield token drains LPs exactly as an arbitrageur does,
    /// so the correction has to apply to organic flow too, not only to detected arbitrage.
    function test_parHook_correctsOrganicFlow() public {
        int256 retailSize = 1e18;

        for (uint16 i = 0; i < PERIODS; i++) {
            vm.warp(block.timestamp + PERIOD);
            vault.accrue(ACCRUAL_PIPS);

            swap(basePool, true, -retailSize, "");
            swap(parPool, true, -retailSize, "");
        }

        uint256 par = vault.rate();

        // corrections are donated into fee growth, so withdrawing the position collects
        // them; nothing extra has to be added by hand here
        uint256 baseValue = _lpValue(basePool, par);
        uint256 parValue = _lpValue(parPool, par);

        console.log("baseline LP value :", baseValue);
        console.log("par-pool LP value :", parValue);
        console.log("uplift (bps)      :", ((parValue - baseValue) * 10_000) / baseValue);

        assertGt(parValue, baseValue, "par-pool LPs should end up ahead");
    }

    /// When a swap leaves the price outside every position, v4 has no in-range liquidity
    /// to donate to. The correction is held instead of being dropped, and LPs claim it.
    function test_heldCorrection_isClaimableWhenDonateCannotPay() public {
        hook.setTrustedRouter(address(modifyLiquidityRouter), true);

        (PoolKey memory narrow,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1);
        hook.configurePool(narrow, IRateSource(address(source)), MAX_APR_PIPS, true);
        _addRange(narrow, -600, 600, LIQUIDITY, bytes32(uint256(1)), address(this));

        vm.warp(block.timestamp + PERIOD * 3);
        vault.accrue(ACCRUAL_PIPS * 3);

        // large enough to walk the price clean out of the only position
        swap(narrow, true, -60e18, "");

        (, uint256 held) = hook.poolRetention(narrow.toId());
        console.log("held for later claim:", held);
        assertGt(held, 0, "correction must be kept when it cannot be donated");

        uint256 before = currency1.balanceOfSelf();
        (, uint256 paid1) = hook.claim(narrow, -600, 600, bytes32(uint256(1)));

        assertGt(paid1, 0, "held correction should be claimable");
        assertEq(currency1.balanceOfSelf() - before, paid1, "tokens should reach the LP");

        (, uint256 afterPending) =
            hook.pendingRetention(narrow.toId(), address(this), -600, 600, bytes32(uint256(1)));
        assertEq(afterPending, 0, "claim should zero the position");
    }

    function test_configurePool_isOwnerOnly() public {
        (PoolKey memory other,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1);

        vm.prank(address(0xBEEF));
        vm.expectRevert(VernierParHook.NotOwner.selector);
        hook.configurePool(other, IRateSource(address(source)), MAX_APR_PIPS, true);
    }

    function test_untrustedRouterCannotSpoofPositionOwner() public {
        address victim = makeAddr("victim");
        _addAs(parPool, LIQUIDITY, bytes32(uint256(7)), victim);

        _runFlow(3);

        (, uint256 pending1) = hook.pendingRetention(parPool.toId(), victim, TICK_LOWER, TICK_UPPER, bytes32(uint256(7)));
        assertEq(pending1, 0, "hookData must be ignored from an untrusted caller");
    }

    function _runFlow(uint16 periods) internal {
        for (uint16 i = 0; i < periods; i++) {
            vm.warp(block.timestamp + PERIOD);
            vault.accrue(ACCRUAL_PIPS);
            swap(parPool, true, -1e18, "");
        }
    }

    function _addAs(PoolKey memory key, int256 liquidity, bytes32 salt, address positionOwner) internal {
        _addRange(key, TICK_LOWER, TICK_UPPER, liquidity, salt, positionOwner);
    }

    function _addRange(
        PoolKey memory key,
        int24 lower,
        int24 upper,
        int256 liquidity,
        bytes32 salt,
        address positionOwner
    ) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidity, salt: salt}),
            abi.encode(positionOwner)
        );
    }

    function _lpValue(PoolKey memory key, uint256 par) internal returns (uint256) {
        BalanceDelta delta = modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -LIQUIDITY, salt: 0}),
            ""
        );
        return uint256(int256(delta.amount0())) + (uint256(int256(delta.amount1())) * par) / 1e18;
    }

    function test_parHook_exactOutputIsNotABypass() public {
        vm.warp(block.timestamp + PERIOD * 6);
        vault.accrue(ACCRUAL_PIPS * 6);
        uint256 par = vault.rate();

        uint256 snap = vm.snapshotState();
        int256 exactIn = _probe(parPool, true, -1e18, par);
        vm.revertToState(snap);

        int256 exactOut = _probe(parPool, true, 1e18, par);

        console.log("exact input profit :");
        console.logInt(exactIn);
        console.log("exact output profit:");
        console.logInt(exactOut);

        assertLe(exactOut, 0, "exact output must not route around the correction");
    }

    function _runArb(PoolKey memory key, uint256 par) internal returns (int256) {
        bool bestDirection;
        int256 bestSize;
        int256 bestProfit;

        for (uint256 d = 0; d < 2; d++) {
            bool zeroForOne = d == 0;
            for (uint256 s = 0; s < SIZES.length; s++) {
                uint256 snap = vm.snapshotState();
                int256 profit = _probe(key, zeroForOne, -SIZES[s], par);
                vm.revertToState(snap);

                if (profit > bestProfit) {
                    bestProfit = profit;
                    bestSize = SIZES[s];
                    bestDirection = zeroForOne;
                }
            }
        }

        if (bestProfit <= 0) return 0;
        swap(key, bestDirection, -bestSize, "");
        return bestProfit;
    }

    function _probe(PoolKey memory key, bool zeroForOne, int256 amount, uint256 par) internal returns (int256) {
        BalanceDelta delta = swap(key, zeroForOne, amount, "");
        return int256(delta.amount0()) + (int256(delta.amount1()) * int256(par)) / 1e18;
    }

    function _add(PoolKey memory key, int256 liquidity) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liquidity, salt: 0}),
            ""
        );
    }
}
