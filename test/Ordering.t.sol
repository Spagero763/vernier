// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VernierParHook} from "../src/VernierParHook.sol";
import {ERC4626RateSource} from "../src/adapters/ERC4626RateSource.sol";
import {IRateSource} from "../src/interfaces/IRateSource.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";

/// Every other suite configures the yield token as currency1. The deployed pool sorts it
/// to currency0, and that flag decides which leg is corrected in all four branches, so
/// the live configuration is the one least exercised. These run the mirrored ordering.
contract OrderingTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    VernierParHook internal hook;
    MockYieldVault internal vault;
    ERC4626RateSource internal source;

    PoolKey internal pool;
    PoolKey internal basePool;

    int24 internal constant TICK_LOWER = -6000;
    int24 internal constant TICK_UPPER = 6000;
    int256 internal constant LIQUIDITY = 100e18;
    uint256 internal constant PERIOD = 30 days;
    uint24 internal constant POOL_FEE = 500;
    uint24 internal constant MAX_APR_PIPS = 200_000;

    // yield token is currency0 here, so buying it means taking currency0 out
    bool internal constant BUY_YIELD = false;
    bool internal constant SELL_YIELD = true;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        vault = new MockYieldVault();
        source = new ERC4626RateSource(address(vault));

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

        // false: the yield token is currency0, matching the deployed pool
        hook.configurePool(pool, IRateSource(address(source)), MAX_APR_PIPS, false);
    }

    /// Curve underprices the token, buyer gains, exact input. The unspecified leg is the
    /// yield output, so the correction must land on currency0.
    function test_mirrored_underpriced_exactInput_correctsYieldLeg() public {
        _accrue(4_000);

        (uint256 extra0, uint256 extra1) = _growthAgainstBaseline(BUY_YIELD, -1e18);

        assertGt(extra0, 0, "correction belongs on the yield leg");
        assertEq(extra1, 0, "quote leg is specified and carries only the ordinary fee");
    }

    /// Same regime, exact output. The unspecified leg flips to the quote input, so the
    /// correction must move with it or exact output becomes a way around the hook.
    function test_mirrored_underpriced_exactOutput_correctsQuoteLeg() public {
        _accrue(4_000);

        (uint256 extra0, uint256 extra1) = _growthAgainstBaseline(BUY_YIELD, 1e18);

        assertGt(extra1, 0, "correction follows the unspecified leg to the quote");
        assertEq(extra0, 0, "yield leg is specified here");
    }

    /// Rate falls, so the curve now overprices the token and the seller is the one taking
    /// the stale side. Exact input: unspecified leg is the quote output.
    function test_mirrored_overpriced_exactInput_correctsQuoteLeg() public {
        vm.warp(block.timestamp + PERIOD);
        vault.setRate(0.99e18);

        (uint256 extra0, uint256 extra1) = _growthAgainstBaseline(SELL_YIELD, -1e18);

        assertGt(extra1, 0, "seller pays on the quote they receive");
        assertEq(extra0, 0, "yield leg is specified here");
    }

    /// Same regime, exact output: unspecified leg is the yield the seller hands over.
    function test_mirrored_overpriced_exactOutput_correctsYieldLeg() public {
        vm.warp(block.timestamp + PERIOD);
        vault.setRate(0.99e18);

        (uint256 extra0, uint256 extra1) = _growthAgainstBaseline(SELL_YIELD, 1e18);

        assertGt(extra0, 0, "seller pays more of the token they are handing over");
        assertEq(extra1, 0, "quote leg is specified here");
    }

    /// Flow on the side the curve has right captures nothing, so it owes nothing.
    function test_mirrored_wrongDirectionPaysNothingExtra() public {
        _accrue(4_000);

        (uint256 extra0, uint256 extra1) = _growthAgainstBaseline(SELL_YIELD, -1e18);

        assertEq(extra0, 0, "no correction on the yield leg");
        assertEq(extra1, 0, "and none on the quote leg either");
    }

    function _accrue(uint256 pips) internal {
        vm.warp(block.timestamp + PERIOD);
        vault.accrue(pips);
    }

    function _add(PoolKey memory key) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: 0}),
            ""
        );
    }

    /// v4 charges the ordinary lp fee on the input leg either way, so the correction only
    /// shows as the difference against a pool with no hook running the same swap.
    function _growthAgainstBaseline(bool zeroForOne, int256 amount)
        internal
        returns (uint256 extra0, uint256 extra1)
    {
        (uint256 vb0, uint256 vb1) = manager.getFeeGrowthGlobals(pool.toId());
        (uint256 bb0, uint256 bb1) = manager.getFeeGrowthGlobals(basePool.toId());

        swap(pool, zeroForOne, amount, "");
        swap(basePool, zeroForOne, amount, "");

        (uint256 va0, uint256 va1) = manager.getFeeGrowthGlobals(pool.toId());
        (uint256 ba0, uint256 ba1) = manager.getFeeGrowthGlobals(basePool.toId());

        extra0 = (va0 - vb0) - (ba0 - bb0);
        extra1 = (va1 - vb1) - (ba1 - bb1);
    }
}
