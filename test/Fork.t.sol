// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VernierParHook} from "../src/VernierParHook.sol";
import {ERC4626RateSource} from "../src/adapters/ERC4626RateSource.sol";
import {IRateSource} from "../src/interfaces/IRateSource.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";

/// Runs against the PoolManager actually deployed on Unichain Sepolia rather than a
/// fresh one. The correction is settled with poolManager.take(), and a mock manager
/// will accept a take that real v4 rejects, so the mechanism is not proven until it
/// clears the deployed contract's accounting.
contract ForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant MANAGER = IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
    string internal constant RPC = "https://sepolia.unichain.org";

    VernierParHook internal hook;
    MockYieldVault internal vault;
    ERC4626RateSource internal source;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;

    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal key;
    bool internal yieldIsCurrency1;

    int24 internal constant TICK_LOWER = -6000;
    int24 internal constant TICK_UPPER = 6000;
    uint24 internal constant POOL_FEE = 500;
    uint24 internal constant MAX_APR_PIPS = 200_000;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function setUp() public {
        vm.createSelectFork(RPC);

        vault = new MockYieldVault();
        source = new ERC4626RateSource(address(vault));
        lpRouter = new PoolModifyLiquidityTest(MANAGER);
        swapRouter = new PoolSwapTest(MANAGER);

        MockERC20 yieldToken = new MockERC20("Staked Yield", "sYIELD", 18);
        MockERC20 quote = new MockERC20("USD Coin", "USDC", 18);

        (address a, address b) = address(yieldToken) < address(quote)
            ? (address(yieldToken), address(quote))
            : (address(quote), address(yieldToken));
        currency0 = Currency.wrap(a);
        currency1 = Currency.wrap(b);
        yieldIsCurrency1 = b == address(yieldToken);

        yieldToken.mint(address(this), 1_000e18);
        quote.mint(address(this), 1_000e18);
        yieldToken.approve(address(lpRouter), type(uint256).max);
        quote.approve(address(lpRouter), type(uint256).max);
        yieldToken.approve(address(swapRouter), type(uint256).max);
        quote.approve(address(swapRouter), type(uint256).max);

        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VernierParHook).creationCode, abi.encode(address(MANAGER), address(this)));
        hook = new VernierParHook{salt: salt}(MANAGER, address(this));
        require(address(hook) == hookAddr, "hook mismatch");

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        MANAGER.initialize(key, SQRT_PRICE_1_1);

        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 50e18, salt: 0}),
            ""
        );

        hook.configurePool(key, IRateSource(address(source)), MAX_APR_PIPS, yieldIsCurrency1);
    }

    function test_fork_correctionReachesLpsOnLiveV4() public {
        vm.warp(block.timestamp + 30 days);
        vault.accrue(4_000);

        uint256 growthBefore = _correctedFeeGrowth();
        _swap(yieldIsCurrency1, -1e18);
        uint256 growthAfter = _correctedFeeGrowth();

        (uint256 retained0, uint256 retained1) = hook.poolRetention(key.toId());

        console.log("block               :", block.number);
        console.log("fee growth delta    :", growthAfter - growthBefore);
        console.log("held in hook instead:", retained0 + retained1);

        assertGt(growthAfter, growthBefore, "correction must land in fee growth on live v4");
        assertEq(retained0 + retained1, 0, "donate path should not fall back to custody");
    }

    /// Exact output corrects the quote leg, which also collects the ordinary LP fee, so
    /// fee growth cannot isolate it. The event proves the correction fired and settled:
    /// a settlement failure would either revert or fall back to CorrectionHeld.
    function test_fork_exactOutputSettlesToo() public {
        vm.warp(block.timestamp + 30 days);
        vault.accrue(4_000);

        vm.recordLogs();
        _swap(yieldIsCurrency1, 1e17);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 priced = keccak256("StalenessPriced(bytes32,uint256,uint256,uint256)");
        bytes32 held = keccak256("CorrectionHeld(bytes32,uint256)");
        uint256 corrected;
        uint256 heldCount;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == priced) {
                (,, corrected) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
            if (logs[i].topics[0] == held) heldCount++;
        }

        console.log("exact output correction:", corrected);

        assertGt(corrected, 0, "exact output must settle its correction too");
        assertEq(heldCount, 0, "and should reach LPs rather than sit in the hook");
    }

    function _correctedFeeGrowth() internal view returns (uint256) {
        (uint256 growth0, uint256 growth1) = MANAGER.getFeeGrowthGlobals(key.toId());
        return yieldIsCurrency1 ? growth1 : growth0;
    }

    function test_fork_uncorrectedDirectionStillSwaps() public {
        vm.warp(block.timestamp + 30 days);
        vault.accrue(4_000);

        _swap(!yieldIsCurrency1, -1e18);
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
