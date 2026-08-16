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
import {IRateAttestor} from "../src/interfaces/IRateAttestor.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";
import {MockRateAttestor} from "./mocks/MockRateAttestor.sol";

/// The attestor exists to answer a question the hook cannot: did the share price move
/// because yield accrued, or because someone inflated the vault. It may only withhold
/// the correction, never set a price, so the worst it can do is turn the pool back into
/// an ordinary AMM.
contract AttestorTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    VernierParHook internal hook;
    MockYieldVault internal vault;
    ERC4626RateSource internal source;
    MockRateAttestor internal attestor;

    PoolKey internal parPool;

    int24 internal constant TICK_LOWER = -6000;
    int24 internal constant TICK_UPPER = 6000;
    int256 internal constant LIQUIDITY = 100e18;
    uint256 internal constant PERIOD = 30 days;
    uint24 internal constant POOL_FEE = 500;
    uint24 internal constant MAX_APR_PIPS = 200_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        vault = new MockYieldVault();
        source = new ERC4626RateSource(address(vault));
        attestor = new MockRateAttestor();

        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VernierParHook).creationCode, abi.encode(address(manager)));
        hook = new VernierParHook{salt: salt}(IPoolManager(address(manager)));
        require(address(hook) == hookAddr, "hook mismatch");

        (parPool,) = initPool(currency0, currency1, IHooks(address(hook)), POOL_FEE, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            parPool,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: 0}),
            ""
        );
        hook.configurePool(parPool, IRateSource(address(source)), MAX_APR_PIPS, true);
    }

    function test_unsoundRate_suspendsTheCorrection() public {
        hook.setAttestor(parPool, IRateAttestor(address(attestor)));
        attestor.setSound(false);

        vm.warp(block.timestamp + PERIOD);
        vault.accrue(4_000);

        uint256 before = _yieldFeeGrowth();
        swap(parPool, true, -1e18, "");

        assertEq(_yieldFeeGrowth(), before, "a disputed rate must not be priced");
    }

    function test_soundRate_correctsNormally() public {
        hook.setAttestor(parPool, IRateAttestor(address(attestor)));

        vm.warp(block.timestamp + PERIOD);
        vault.accrue(4_000);

        uint256 before = _yieldFeeGrowth();
        swap(parPool, true, -1e18, "");

        assertGt(_yieldFeeGrowth(), before, "an attested rate should be priced as usual");
    }

    /// An attestor that goes down must not take the venue with it.
    function test_brokenAttestor_doesNotHaltThePool() public {
        hook.setAttestor(parPool, IRateAttestor(address(attestor)));
        attestor.setBroken(true);

        vm.warp(block.timestamp + PERIOD);
        vault.accrue(4_000);

        uint256 before = _yieldFeeGrowth();
        swap(parPool, true, -1e18, "");

        assertGt(_yieldFeeGrowth(), before, "hook should fall back to its own bounds");
    }

    function test_attestorIsOwnerOnly() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(VernierParHook.NotOwner.selector);
        hook.setAttestor(parPool, IRateAttestor(address(attestor)));
    }

    function _yieldFeeGrowth() internal view returns (uint256) {
        (, uint256 growth1) = manager.getFeeGrowthGlobals(parPool.toId());
        return growth1;
    }
}
