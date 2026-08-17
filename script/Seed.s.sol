// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VernierParHook} from "../src/VernierParHook.sol";
import {VernierSwapRouter} from "../src/periphery/VernierSwapRouter.sol";
import {MockYieldVault} from "../test/mocks/MockYieldVault.sol";

/// Seeds both pools identically, accrues yield, then trades the arb direction on each.
/// The fee growth afterwards is the whole claim: the same accrual and the same trade
/// leave value with the hooked pool's LPs and not with the plain pool's.
///
/// Accrual is scaled to the time actually elapsed. Minting a flat 0.2% on demand implies
/// an APR in the thousands, which the hook's plausibility bound correctly refuses, and the
/// run then measures the guard rather than the mechanism. Run this repeatedly over days to
/// let the position build the way a real one would.
contract Seed is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant DEFAULT_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    uint24 internal constant POOL_FEE = 500;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int256 internal constant LIQUIDITY = 50e18;
    int256 internal constant TRADE = 1e17;

    struct Env {
        address poolManager;
        address hook;
        address usdc;
        address syield;
        address vault;
        address lpRouter;
        address swapRouter;
    }

    function run() external {
        Env memory e = Env({
            poolManager: vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER),
            hook: vm.envAddress("VERNIER_HOOK"),
            usdc: vm.envAddress("VERNIER_USDC"),
            syield: vm.envAddress("VERNIER_SYIELD"),
            vault: vm.envAddress("VERNIER_VAULT"),
            lpRouter: vm.envAddress("VERNIER_LP_ROUTER"),
            swapRouter: vm.envAddress("VERNIER_SWAP_ROUTER")
        });

        vm.startBroadcast();
        _fund(e);
        _seed(e);
        vm.stopBroadcast();

        _report(e);
    }

    function _fund(Env memory e) internal {
        MockERC20(e.usdc).mint(msg.sender, 1_000_000e18);
        MockERC20(e.syield).mint(msg.sender, 1_000_000e18);
        MockERC20(e.usdc).approve(e.lpRouter, type(uint256).max);
        MockERC20(e.syield).approve(e.lpRouter, type(uint256).max);
        MockERC20(e.usdc).approve(e.swapRouter, type(uint256).max);
        MockERC20(e.syield).approve(e.swapRouter, type(uint256).max);
    }

    function _seed(Env memory e) internal {
        (address c0, address c1) = e.usdc < e.syield ? (e.usdc, e.syield) : (e.syield, e.usdc);

        _addLiquidity(PoolModifyLiquidityTest(e.lpRouter), _key(c0, c1, e.hook));
        _addLiquidity(PoolModifyLiquidityTest(e.lpRouter), _key(c0, c1, address(0)));

        _accrue(e, _key(c0, c1, e.hook));

        // buying the now underpriced yield token is the side the stale curve favours
        bool zeroForOne = c0 == e.usdc;
        _trade(VernierSwapRouter(e.swapRouter), _key(c0, c1, e.hook), zeroForOne);
        _trade(VernierSwapRouter(e.swapRouter), _key(c0, c1, address(0)), zeroForOne);
    }

    /// Half the bound, so the demo reflects the correction rather than the clamp.
    function _accrue(Env memory e, PoolKey memory vernierPool) internal {
        (,, uint64 lastRateAt, uint24 maxRateAprPips,,) = VernierParHook(e.hook).configOf(vernierPool.toId());

        uint256 elapsed = block.timestamp - lastRateAt;
        uint256 pips = (uint256(maxRateAprPips) * elapsed) / (365 days) / 2;
        if (pips == 0) pips = 1;

        console.log("elapsed since last rate move (s):", elapsed);
        console.log("accruing (pips)                 :", pips);
        MockYieldVault(e.vault).accrue(pips);
    }

    function _report(Env memory e) internal view {
        (address c0, address c1) = e.usdc < e.syield ? (e.usdc, e.syield) : (e.syield, e.usdc);

        (uint256 base0, uint256 base1) =
            IPoolManager(e.poolManager).getFeeGrowthGlobals(_key(c0, c1, address(0)).toId());
        (uint256 vern0, uint256 vern1) = IPoolManager(e.poolManager).getFeeGrowthGlobals(_key(c0, c1, e.hook).toId());

        console.log("baseline fee growth 0/1:", base0, base1);
        console.log("vernier  fee growth 0/1:", vern0, vern1);
    }

    function _key(address c0, address c1, address hookAddr) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
    }

    function _addLiquidity(PoolModifyLiquidityTest lpRouter, PoolKey memory key) internal {
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: 0}),
            ""
        );
    }

    function _trade(VernierSwapRouter swapRouter, PoolKey memory key, bool zeroForOne) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -TRADE,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }
}
