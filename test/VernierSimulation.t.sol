// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VernierHook} from "../src/VernierHook.sol";
import {ERC4626RateSource} from "../src/adapters/ERC4626RateSource.sol";
import {IRateSource} from "../src/interfaces/IRateSource.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";

contract VernierSimulationTest is Test, Deployers {
    VernierHook internal hook;
    MockYieldVault internal vault;
    ERC4626RateSource internal source;

    PoolKey internal basePool;
    PoolKey internal vernierPool;

    int24 internal constant TICK_LOWER = -6000;
    int24 internal constant TICK_UPPER = 6000;
    int256 internal constant LIQUIDITY = 100e18;

    uint16 internal constant PERIODS = 12;
    uint256 internal constant ACCRUAL_PIPS = 4_000; // 0.4% per period, ~4.9% per year
    int256 internal constant FLOW = 10e18; // trading flow per period, ~10% of TVL
    uint24 internal constant BASELINE_FEE = 500; // 5 bps static

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

    function test_simulation_vernierLpsKeepMore() public {
        for (uint16 i = 0; i < PERIODS; i++) {
            vault.accrue(ACCRUAL_PIPS);
            bool zeroForOne = (i % 2 == 0);
            swap(basePool, zeroForOne, -FLOW, "");
            swap(vernierPool, zeroForOne, -FLOW, "");
        }

        uint256 par = vault.rate();
        uint256 baseValue = _lpValue(basePool, par);
        uint256 vernierValue = _lpValue(vernierPool, par);

        uint256 upliftBps = ((vernierValue - baseValue) * 10_000) / baseValue;

        (,, uint256 totalRetained) = hook.poolRetention(vernierPool.toId());

        console.log("periods                :", PERIODS);
        console.log("final par (1e18)       :", par);
        console.log("baseline LP value      :", baseValue);
        console.log("vernier LP value         :", vernierValue);
        console.log("uplift (bps)           :", upliftBps);
        console.log("yield retained for LPs :", totalRetained);

        assertGt(vernierValue, baseValue);
        assertGt(totalRetained, 0);
    }

    function _add(PoolKey memory key, int256 liquidity) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liquidity, salt: 0}),
            ""
        );
    }

    function _lpValue(PoolKey memory key, uint256 par) internal returns (uint256) {
        BalanceDelta delta = modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -LIQUIDITY, salt: 0}),
            ""
        );
        uint256 amount0 = uint256(int256(delta.amount0()));
        uint256 amount1 = uint256(int256(delta.amount1()));
        return amount0 + (amount1 * par) / 1e18;
    }
}
