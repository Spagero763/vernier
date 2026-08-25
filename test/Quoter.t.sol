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
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {VernierParHook} from "../src/VernierParHook.sol";
import {ERC4626RateSource} from "../src/adapters/ERC4626RateSource.sol";
import {IRateSource} from "../src/interfaces/IRateSource.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";

/// The swap interface will not route these pools natively, because the hook returns a
/// delta and execution therefore differs from what the curve alone implies. That is a
/// property of the mechanism, not a gap in it, and it does not make the pool opaque:
/// the v4 Quoter simulates hooks, so an integrator can still price a swap correctly
/// before sending it. These assert the quote matches what the swap actually pays.
contract QuoterTest is Test, Deployers {
    VernierParHook internal hook;
    MockYieldVault internal vault;
    ERC4626RateSource internal source;
    V4Quoter internal quoter;

    PoolKey internal pool;
    PoolKey internal basePool;

    int24 internal constant TICK_LOWER = -6000;
    int24 internal constant TICK_UPPER = 6000;
    int256 internal constant LIQUIDITY = 100e18;
    uint256 internal constant PERIOD = 30 days;
    uint24 internal constant POOL_FEE = 500;
    uint24 internal constant MAX_APR_PIPS = 200_000;
    uint128 internal constant AMOUNT = 1e18;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        vault = new MockYieldVault();
        source = new ERC4626RateSource(address(vault));
        quoter = new V4Quoter(manager);

        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), flags, type(VernierParHook).creationCode, abi.encode(address(manager), address(this))
        );
        hook = new VernierParHook{salt: salt}(IPoolManager(address(manager)), address(this));
        require(address(hook) == hookAddr, "hook mismatch");

        (pool,) = initPool(currency0, currency1, IHooks(address(hook)), POOL_FEE, 60, SQRT_PRICE_1_1);
        (basePool,) = initPool(currency0, currency1, IHooks(address(0)), POOL_FEE, 60, SQRT_PRICE_1_1);
        _add(pool);
        _add(basePool);

        hook.configurePool(pool, IRateSource(address(source)), MAX_APR_PIPS, true);
    }

    /// A quote that ignored the hook would overstate the output by the correction, which
    /// is precisely the amount an integrator would have mispriced by.
    function test_quoteMatchesWhatTheSwapActuallyPays() public {
        _accrue();

        (uint256 quoted,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: pool, zeroForOne: true, exactAmount: AMOUNT, hookData: ""})
        );

        BalanceDelta delta = swap(pool, true, -int256(uint256(AMOUNT)), "");
        uint256 received = uint256(uint128(delta.amount1()));

        console.log("quoted   :", quoted);
        console.log("received :", received);

        assertEq(quoted, received, "quote must equal execution or the pool is unroutable in practice");
    }

    /// The quote is lower than the same pool without the hook, and the difference is the
    /// correction being priced in rather than handed to the caller.
    function test_quoteIsBelowTheBarePoolByTheCorrection() public {
        _accrue();

        (uint256 hooked,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: pool, zeroForOne: true, exactAmount: AMOUNT, hookData: ""})
        );
        (uint256 bare,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: basePool, zeroForOne: true, exactAmount: AMOUNT, hookData: ""})
        );

        console.log("bare pool quote  :", bare);
        console.log("vernier quote    :", hooked);
        console.log("difference       :", bare - hooked);

        assertLt(hooked, bare, "the correction should show up in the quote");
    }

    /// Exact output is quotable too, so an integrator is not pushed onto one swap type.
    function test_exactOutputIsQuotable() public {
        _accrue();

        (uint256 quoted,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: pool, zeroForOne: true, exactAmount: AMOUNT, hookData: ""})
        );

        BalanceDelta delta = swap(pool, true, int256(uint256(AMOUNT)), "");
        uint256 paid = uint256(uint128(-delta.amount0()));

        console.log("quoted input:", quoted);
        console.log("actual input:", paid);

        assertEq(quoted, paid, "exact output must quote as accurately as exact input");
    }

    function _accrue() internal {
        vm.warp(block.timestamp + PERIOD);
        vault.accrue(4_000);
    }

    function _add(PoolKey memory key) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: 0}),
            ""
        );
    }
}
