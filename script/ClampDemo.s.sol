// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {VernierParHook} from "../src/VernierParHook.sol";
import {VernierSwapRouter} from "../src/periphery/VernierSwapRouter.sol";
import {MockYieldVault} from "../test/mocks/MockYieldVault.sol";

/// Deliberately reports a rate no real yield token could produce, to show the bound
/// rejecting it on-chain. The RateClamped event this leaves is the evidence: a rate
/// source cannot move the price further than elapsed time can justify, however loudly
/// it insists otherwise.
///
/// The spike is reverted once the event exists. Left in place it would take the accepted
/// rate about two years to catch up at a 20% bound, so every later swap would be throttled
/// and the venue would sit permanently clamped. The event is the artefact worth keeping,
/// not the state.
contract ClampDemo is Script {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant POOL_FEE = 500;
    int24 internal constant TICK_SPACING = 60;
    int256 internal constant TRADE = 1e16;

    function run() external {
        address hookAddr = vm.envAddress("VERNIER_HOOK");
        address usdc = vm.envAddress("VERNIER_USDC");
        address syield = vm.envAddress("VERNIER_SYIELD");
        address vault = vm.envAddress("VERNIER_VAULT");
        address swapRouter = vm.envAddress("VERNIER_SWAP_ROUTER");

        (address c0, address c1) = usdc < syield ? (usdc, syield) : (syield, usdc);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });

        uint256 before = MockYieldVault(vault).rate();
        uint256 accepted = VernierParHook(hookAddr).lastRateOf(key.toId());

        vm.startBroadcast();

        // a 40% jump in one reading, which no staking or lending rate produces
        MockYieldVault(vault).accrue(400_000);

        bool zeroForOne = c0 == usdc;
        VernierSwapRouter(swapRouter).swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -TRADE,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        uint256 spiked = MockYieldVault(vault).rate();

        // the event is permanent, the distorted rate should not be
        MockYieldVault(vault).setRate(before);

        vm.stopBroadcast();

        console.log("rate before          :", before);
        console.log("rate reported (spike):", spiked);
        console.log("rate restored to     :", MockYieldVault(vault).rate());
        console.log("accepted before      :", accepted);
        console.log("accepted after       :", VernierParHook(hookAddr).lastRateOf(key.toId()));
        console.log("RateClamped on the hook records the reading that was refused");
    }
}
