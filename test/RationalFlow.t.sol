// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VernierHook} from "../src/VernierHook.sol";
import {ERC4626RateSource} from "../src/adapters/ERC4626RateSource.sol";
import {IRateSource} from "../src/interfaces/IRateSource.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";

/// Flow here is rational: an arbitrageur trades only when the trade actually pays.
/// The existing simulation swaps every period unconditionally, which supplies
/// correction flow no profit-seeking actor would supply.
contract RationalFlowTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    VernierHook internal hook;
    MockYieldVault internal vault;
    ERC4626RateSource internal source;

    PoolKey internal basePool;
    PoolKey internal vernierPool;

    int24 internal constant TICK_LOWER = -6000;
    int24 internal constant TICK_UPPER = 6000;
    int256 internal constant LIQUIDITY = 100e18;

    uint16 internal constant PERIODS = 12;
    uint256 internal constant ACCRUAL_PIPS = 4_000;
    uint24 internal constant BASELINE_FEE = 500;

    int256[8] internal SIZES =
        [int256(0.01e18), 0.05e18, 0.1e18, 0.25e18, 0.5e18, 1e18, 2e18, 5e18];

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        vault = new MockYieldVault();
        source = new ERC4626RateSource(address(vault));

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VernierHook).creationCode, abi.encode(address(manager)));
        hook = new VernierHook{salt: salt}(IPoolManager(address(manager)));
        require(address(hook) == hookAddr, "hook mismatch");

        (basePool,) = initPool(currency0, currency1, IHooks(address(0)), BASELINE_FEE, 60, SQRT_PRICE_1_1);
        (vernierPool,) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);

        _add(basePool, LIQUIDITY);
        _add(vernierPool, LIQUIDITY);

        hook.configurePool(vernierPool, IRateSource(address(source)), 50_000, 100_000, true);
    }

    function test_rationalArb_baselineConvergesVernierDoesNot() public {
        uint256 baseTrades;
        uint256 vernierTrades;

        for (uint16 i = 0; i < PERIODS; i++) {
            vault.accrue(ACCRUAL_PIPS);
            uint256 par = vault.rate();

            if (_tryArb(basePool, par)) baseTrades++;
            if (_tryArb(vernierPool, par)) vernierTrades++;
        }

        uint256 finalPar = vault.rate();
        uint256 baseGap = _gapPips(basePool, finalPar);
        uint256 vernierGap = _gapPips(vernierPool, finalPar);

        console.log("periods                  :", PERIODS);
        console.log("baseline arb trades      :", baseTrades);
        console.log("vernier arb trades       :", vernierTrades);
        console.log("baseline final gap (pips):", baseGap);
        console.log("vernier final gap (pips) :", vernierGap);

        assertGt(baseTrades, 0, "baseline should attract correcting flow");
        assertEq(vernierTrades, 0, "v2 fee makes correction unprofitable");
        assertGt(vernierGap, baseGap, "v2 pool drifts further from par");
    }

    function test_rationalArb_vernierGapGrowsMonotonically() public {
        uint256 previousGap;

        for (uint16 i = 0; i < PERIODS; i++) {
            vault.accrue(ACCRUAL_PIPS);
            uint256 par = vault.rate();
            _tryArb(vernierPool, par);

            uint256 gap = _gapPips(vernierPool, par);
            assertGe(gap, previousGap, "gap should never close without correcting flow");
            previousGap = gap;
        }

        console.log("vernier gap after 12 periods (pips):", previousGap);
        assertGt(previousGap, ACCRUAL_PIPS * 4, "gap compounds with accrual");
    }

    /// A real arbitrageur sizes the trade to the gap. Scanning a ladder and taking the
    /// best profitable size approximates that; a fixed size large enough to matter costs
    /// more in price impact than the gap is worth, and reads as "no arb exists".
    function _tryArb(PoolKey memory key, uint256 par) internal returns (bool) {
        bool bestDirection;
        int256 bestSize;
        int256 bestProfit;

        for (uint256 d = 0; d < 2; d++) {
            bool zeroForOne = d == 0;

            for (uint256 s = 0; s < SIZES.length; s++) {
                int256 size = SIZES[s];

                uint256 snap = vm.snapshotState();
                int256 profit = _probe(key, zeroForOne, size, par);
                vm.revertToState(snap);

                if (profit > bestProfit) {
                    bestProfit = profit;
                    bestSize = size;
                    bestDirection = zeroForOne;
                }
            }
        }

        if (bestProfit <= 0) return false;
        swap(key, bestDirection, -bestSize, "");
        return true;
    }

    /// Trader nets out at par: currency1 is the yield token, worth `par` of currency0.
    function _probe(PoolKey memory key, bool zeroForOne, int256 size, uint256 par) internal returns (int256) {
        BalanceDelta delta = swap(key, zeroForOne, -size, "");
        return int256(delta.amount0()) + (int256(delta.amount1()) * int256(par)) / 1e18;
    }

    function _gapPips(PoolKey memory key, uint256 par) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        uint256 poolPrice = FullMath.mulDiv(priceX96, 1e18, FixedPoint96.Q96);
        uint256 fairPrice = FullMath.mulDiv(1e18, 1e18, par);

        if (poolPrice >= fairPrice) return ((poolPrice - fairPrice) * 1_000_000) / fairPrice;
        return ((fairPrice - poolPrice) * 1_000_000) / poolPrice;
    }

    function _add(PoolKey memory key, int256 liquidity) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liquidity, salt: 0}),
            ""
        );
    }
}
