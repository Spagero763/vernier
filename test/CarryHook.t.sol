// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {CarryHook} from "../src/CarryHook.sol";
import {ERC4626RateSource} from "../src/adapters/ERC4626RateSource.sol";
import {StETHRateSource} from "../src/adapters/StETHRateSource.sol";
import {IRateSource} from "../src/interfaces/IRateSource.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";
import {MockStETH} from "./mocks/MockStETH.sol";
import {ToggleRateSource} from "./mocks/ToggleRateSource.sol";

contract CarryHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    CarryHook internal hook;
    MockYieldVault internal vault;
    ERC4626RateSource internal source;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 internal constant MAX_FEE = 50_000; // 5%
    uint24 internal constant MAX_JUMP = 100_000; // 10%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        vault = new MockYieldVault();
        source = new ERC4626RateSource(address(vault));

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CarryHook).creationCode, abi.encode(address(manager)));
        hook = new CarryHook{salt: salt}(IPoolManager(address(manager)));
        require(address(hook) == hookAddr, "hook address mismatch");

        (poolKey, poolId) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        // the yield-bearing token is currency1 in these pools
        hook.configurePool(poolKey, IRateSource(address(source)), MAX_FEE, MAX_JUMP, true);
    }

    function test_configuration_recordsBaselineRate() public view {
        assertEq(hook.lastRateOf(poolId), 1e18);
        (, uint24 maxFeePips,,, bool configured) = hook.configOf(poolId);
        assertTrue(configured);
        assertEq(maxFeePips, MAX_FEE);
    }

    function test_configure_revertsOnSecondCall() public {
        vm.expectRevert(CarryHook.PoolAlreadyConfigured.selector);
        hook.configurePool(poolKey, IRateSource(address(source)), MAX_FEE, MAX_JUMP, true);
    }

    function test_noAccrual_chargesZeroFee() public {
        swap(poolKey, true, -1e15, "");
        assertEq(hook.lastRateOf(poolId), 1e18);
    }

    function test_accruedYield_chargesMatchingFee() public {
        // 0.2% of yield accrues between swaps
        vault.accrue(2_000);

        vm.recordLogs();
        swap(poolKey, true, -1e15, "");

        // lastRate advances to the accrued rate
        assertEq(hook.lastRateOf(poolId), vault.rate());

        // fee charged should equal the 2000 pip pool-vs-par gap (below the 5% clamp)
        uint24 charged = _lastYieldRetainedFee();
        assertApproxEqAbs(charged, 2_000, 1);
    }

    function test_wrongDirection_paysNoSurcharge() public {
        vault.accrue(2_000);

        // selling the underpriced yield token is not the arb; no surcharge
        vm.recordLogs();
        swap(poolKey, false, -1e15, "");
        assertEq(_lastYieldRetainedFee(), 0);
    }

    function test_dustSwap_cannotClearTheFee() public {
        vault.accrue(2_000);

        // a 1 wei swap pays the fee on dust but cannot move the pool to par
        vm.recordLogs();
        swap(poolKey, true, -1, "");
        assertApproxEqAbs(_lastYieldRetainedFee(), 2_000, 1);

        // the gap persists, so the next swap is still charged in full
        vm.recordLogs();
        swap(poolKey, true, -1e15, "");
        assertApproxEqAbs(_lastYieldRetainedFee(), 2_000, 5);
    }

    function test_largeAccrual_isClampedToMaxFee() public {
        // 8% accrual but jump ceiling is 10%, fee clamp is 5%
        vault.accrue(80_000);

        vm.recordLogs();
        swap(poolKey, true, -1e15, "");

        uint24 charged = _lastYieldRetainedFee();
        assertEq(charged, MAX_FEE);
    }

    function test_implausibleJump_reverts() public {
        // 20% jump exceeds the 10% ceiling; the hook revert bubbles up wrapped by the manager
        vault.accrue(200_000);
        vm.expectRevert();
        swap(poolKey, true, -1e15, "");
    }

    function test_retention_proportionalToLiquidity() public {
        bytes32 saltA = bytes32(uint256(1));
        bytes32 saltB = bytes32(uint256(2));
        _addLiquidity(saltA, 1e18);
        _addLiquidity(saltB, 2e18);

        vault.accrue(2_000);
        swap(poolKey, true, -1e15, "");

        uint256 pendingA = hook.pendingRetention(poolId, address(modifyLiquidityRouter), -120, 120, saltA);
        uint256 pendingB = hook.pendingRetention(poolId, address(modifyLiquidityRouter), -120, 120, saltB);

        assertGt(pendingA, 0);
        assertEq(pendingB, 2 * pendingA);
    }

    function test_retention_accruesIntoLedger() public {
        vault.accrue(2_000);
        swap(poolKey, true, -1e15, "");

        (,, uint256 totalRetained) = hook.poolRetention(poolId);
        assertGt(totalRetained, 0);

        // the baseline position from setUp earns a share
        uint256 pendingBaseline = hook.pendingRetention(poolId, address(modifyLiquidityRouter), -120, 120, bytes32(0));
        assertGt(pendingBaseline, 0);
    }

    function test_retention_conserved() public {
        bytes32 saltA = bytes32(uint256(11));
        _addLiquidity(saltA, 3e18);

        vault.accrue(5_000);
        swap(poolKey, true, -1e15, "");

        (,, uint256 totalRetained) = hook.poolRetention(poolId);
        uint256 pendingBaseline = hook.pendingRetention(poolId, address(modifyLiquidityRouter), -120, 120, bytes32(0));
        uint256 pendingA = hook.pendingRetention(poolId, address(modifyLiquidityRouter), -120, 120, saltA);

        // all retained value is attributed to the two positions, within integer rounding
        assertApproxEqAbs(pendingBaseline + pendingA, totalRetained, 2);
    }

    function test_retention_settlesOnRemove() public {
        bytes32 saltA = bytes32(uint256(3));
        _addLiquidity(saltA, 1e18);

        vault.accrue(2_000);
        swap(poolKey, true, -1e15, "");

        uint256 before = hook.pendingRetention(poolId, address(modifyLiquidityRouter), -120, 120, saltA);
        assertGt(before, 0);

        // remove half; settled value is preserved, no new accrual happens
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -0.5e18, salt: saltA}),
            ""
        );

        uint256 afterRemove = hook.pendingRetention(poolId, address(modifyLiquidityRouter), -120, 120, saltA);
        assertEq(afterRemove, before);
    }

    function test_stETHAdapter_readsPooledEthRate() public {
        MockStETH steth = new MockStETH();
        steth.setPooledEthPerShare(1.05e18);
        StETHRateSource s = new StETHRateSource(address(steth));
        assertEq(s.getRate(), 1.05e18);
    }

    function test_rateUnavailable_fallsBackToZeroFee() public {
        ToggleRateSource src = new ToggleRateSource();
        (PoolKey memory k, PoolId pid) = _initConfiguredPool(IRateSource(address(src)), 10);

        src.setReverting(true);
        uint256 lastBefore = hook.lastRateOf(pid);

        vm.recordLogs();
        swap(k, true, -1e15, "");

        // swap still succeeds, no fee charged, baseline untouched
        assertEq(hook.lastRateOf(pid), lastBefore);
        assertTrue(_hasTopic(keccak256("RateUnavailable(bytes32)")));
    }

    function test_slashing_flipsArbDirection() public {
        ToggleRateSource src = new ToggleRateSource();
        (PoolKey memory k, PoolId pid) = _initConfiguredPool(IRateSource(address(src)), 30);

        // slashing: the yield token is now worth less, so the pool overprices it
        // and the arb direction flips to selling into the pool the other way
        src.setRate(0.99e18);

        vm.recordLogs();
        swap(k, true, -1e15, "");
        assertEq(_lastYieldRetainedFee(), 0);
        assertEq(hook.lastRateOf(pid), 0.99e18);

        // the true arb direction is charged the gap
        vm.recordLogs();
        swap(k, false, -1e15, "");
        assertGt(_lastYieldRetainedFee(), 0);
    }

    function _initConfiguredPool(IRateSource src, int24 tickSpacing)
        internal
        returns (PoolKey memory k, PoolId pid)
    {
        (k, pid) = initPool(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, SQRT_PRICE_1_1
        );
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 10e18, salt: 0}),
            ""
        );
        hook.configurePool(k, src, MAX_FEE, MAX_JUMP, true);
    }

    function _hasTopic(bytes32 topic) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    function _addLiquidity(bytes32 salt, int256 amount) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: amount, salt: salt}),
            ""
        );
    }

    function _lastYieldRetainedFee() internal returns (uint24) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("YieldRetained(bytes32,uint256,uint256,uint24,uint256)");
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == topic) {
                (,, uint24 feePips,) = abi.decode(logs[i - 1].data, (uint256, uint256, uint24, uint256));
                return feePips;
            }
        }
        revert("no YieldRetained log");
    }
}
