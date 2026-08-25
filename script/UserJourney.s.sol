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
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VernierParHook} from "../src/VernierParHook.sol";
import {VernierSwapRouter} from "../src/periphery/VernierSwapRouter.sol";
import {MockYieldVault} from "../test/mocks/MockYieldVault.sol";

/// Walks the dashboard's own path against the live deployment, as a wallet that has
/// never touched the venue: mint, approve, accrue, trade both pools. Run without
/// broadcast. If this reverts, a visitor clicking the same buttons gets the same revert.
contract UserJourney is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 internal constant POOL_FEE = 500;
    int24 internal constant TICK_SPACING = 60;
    int256 internal constant TRADE = 1e16;

    function run() external {
        address pm = vm.envAddress("POOL_MANAGER");
        address hook = vm.envAddress("VERNIER_HOOK");
        address usdc = vm.envAddress("VERNIER_USDC");
        address syield = vm.envAddress("VERNIER_SYIELD");
        address vault = vm.envAddress("VERNIER_VAULT");
        address router = vm.envAddress("VERNIER_SWAP_ROUTER");

        address visitor = makeAddr("visitor");
        console.log("acting as a fresh wallet:", visitor);

        (address c0, address c1) = usdc < syield ? (usdc, syield) : (syield, usdc);
        PoolKey memory vernierPool = _key(c0, c1, hook);
        PoolKey memory basePool = _key(c0, c1, address(0));

        vm.startPrank(visitor);

        console.log("1. mint test tokens");
        MockERC20(usdc).mint(visitor, 1_000e18);
        MockERC20(syield).mint(visitor, 1_000e18);

        console.log("2. approve the router");
        MockERC20(usdc).approve(router, type(uint256).max);
        MockERC20(syield).approve(router, type(uint256).max);

        console.log("3. accrue yield");
        MockYieldVault(vault).accrue(50);

        // the yield token is currency1 in this deployment, so buying it is zero for one
        bool zeroForOne = c1 == syield;
        console.log("4. trade the vernier pool");
        _trade(router, vernierPool, zeroForOne);

        console.log("5. trade the baseline pool");
        _trade(router, basePool, zeroForOne);

        vm.stopPrank();

        (, uint256 vern1) = IPoolManager(pm).getFeeGrowthGlobals(vernierPool.toId());
        (, uint256 base1) = IPoolManager(pm).getFeeGrowthGlobals(basePool.toId());

        console.log("");
        console.log("yield-leg fee growth, vernier :", vern1);
        console.log("yield-leg fee growth, baseline:", base1);
        require(vern1 > base1, "hook kept nothing the baseline did not");
        console.log("journey completed, correction present");
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

    function _trade(address router, PoolKey memory key, bool zeroForOne) internal {
        VernierSwapRouter(router).swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -TRADE,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }
}
