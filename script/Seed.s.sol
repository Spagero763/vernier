// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VernierHook} from "../src/VernierHook.sol";
import {VernierSwapRouter} from "../src/periphery/VernierSwapRouter.sol";
import {MockYieldVault} from "../test/mocks/MockYieldVault.sol";

contract Seed is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant DEFAULT_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address internal constant DEFAULT_HOOK = 0x42Fc745Bff704DbCC2C6e135404bdE5d0d004680;
    address internal constant DEFAULT_USDC = 0x2Ac1c021461eAA17A4cfef7C8E1d7910D9618C80;
    address internal constant DEFAULT_SYIELD = 0x6bc261d74528D41ac76C9d192BD6E11e707C0733;
    address internal constant DEFAULT_VAULT = 0x3611D872EC05DFae793530973EF4e68bac947ad0;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int256 internal constant LIQUIDITY = 50e18;

    function run() external {
        address poolManager = vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER);
        address hookAddr = vm.envOr("VERNIER_HOOK", DEFAULT_HOOK);
        address usdc = vm.envOr("VERNIER_USDC", DEFAULT_USDC);
        address syield = vm.envOr("VERNIER_SYIELD", DEFAULT_SYIELD);
        address vault = vm.envOr("VERNIER_VAULT", DEFAULT_VAULT);

        vm.startBroadcast();

        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(IPoolManager(poolManager));
        VernierSwapRouter swapRouter = new VernierSwapRouter(IPoolManager(poolManager));

        MockERC20(usdc).mint(msg.sender, 1_000_000e18);
        MockERC20(syield).mint(msg.sender, 1_000_000e18);
        MockERC20(usdc).approve(address(lpRouter), type(uint256).max);
        MockERC20(syield).approve(address(lpRouter), type(uint256).max);
        MockERC20(usdc).approve(address(swapRouter), type(uint256).max);
        MockERC20(syield).approve(address(swapRouter), type(uint256).max);

        (address c0, address c1) = usdc < syield ? (usdc, syield) : (syield, usdc);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: 0}),
            ""
        );

        // accrue 0.2% of yield, then trade in the arb direction (buying the now
        // underpriced yield token) so the hook retains the gap for LPs
        MockYieldVault(vault).accrue(2_000);

        bool zeroForOne = c0 == usdc;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e17,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        vm.stopBroadcast();

        (,, uint256 totalRetained) = VernierHook(hookAddr).poolRetention(key.toId());
        console.log("lpRouter        :", address(lpRouter));
        console.log("swapRouter      :", address(swapRouter));
        console.log("total retained  :", totalRetained);
    }
}
