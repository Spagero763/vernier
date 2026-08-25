// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VernierParHook} from "../src/VernierParHook.sol";
import {RateAttestationService} from "../src/avs/RateAttestationService.sol";
import {VernierSwapRouter} from "../src/periphery/VernierSwapRouter.sol";
import {ERC4626RateSource} from "../src/adapters/ERC4626RateSource.sol";
import {IRateSource} from "../src/interfaces/IRateSource.sol";
import {IRateAttestor} from "../src/interfaces/IRateAttestor.sol";
import {MockYieldVault} from "../test/mocks/MockYieldVault.sol";

/// Deploys the venue plus an identical pool with no hook attached, so the difference
/// between them can be read off-chain rather than asserted.
contract Deploy is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint24 internal constant POOL_FEE = 500;
    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant MAX_RATE_APR_PIPS = 200_000;
    uint16 internal constant QUORUM_BPS = 6667;
    uint64 internal constant FRESHNESS_WINDOW = 1 hours;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int256 internal constant INITIAL_LIQUIDITY = 50e18;

    struct Deployment {
        address hook;
        address attestor;
        address usdc;
        address syield;
        address vault;
        address source;
        address lpRouter;
        address swapRouter;
    }

    function run() external {
        address poolManager = vm.envOr("POOL_MANAGER", UNICHAIN_SEPOLIA_POOL_MANAGER);

        vm.startBroadcast();
        Deployment memory d = _deploy(poolManager, msg.sender);
        bool yieldIsCurrency1 = _wire(poolManager, d);
        vm.stopBroadcast();

        console.log("PoolManager     :", poolManager);
        console.log("VernierParHook  :", d.hook);
        console.log("Attestor        :", d.attestor);
        console.log("USDC            :", d.usdc);
        console.log("sYIELD          :", d.syield);
        console.log("Vault           :", d.vault);
        console.log("RateSource      :", d.source);
        console.log("lpRouter        :", d.lpRouter);
        console.log("swapRouter      :", d.swapRouter);
        console.log("yieldIsCurrency1:", yieldIsCurrency1);
    }

    function _deploy(address poolManager, address deployer) internal returns (Deployment memory d) {
        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(VernierParHook).creationCode, abi.encode(poolManager, deployer)
        );
        VernierParHook hook = new VernierParHook{salt: salt}(IPoolManager(poolManager), deployer);
        require(address(hook) == hookAddr, "hook address mismatch");

        d.hook = address(hook);
        d.attestor = address(new RateAttestationService(QUORUM_BPS, FRESHNESS_WINDOW));
        d.usdc = address(new MockERC20("USD Coin", "USDC", 18));
        d.syield = address(new MockERC20("Staked USD", "sUSD", 18));
        d.vault = address(new MockYieldVault());
        d.source = address(new ERC4626RateSource(d.vault));
        d.lpRouter = address(new PoolModifyLiquidityTest(IPoolManager(poolManager)));
        d.swapRouter = address(new VernierSwapRouter(IPoolManager(poolManager)));
    }

    function _wire(address poolManager, Deployment memory d) internal returns (bool yieldIsCurrency1) {
        (address c0, address c1) = d.usdc < d.syield ? (d.usdc, d.syield) : (d.syield, d.usdc);
        yieldIsCurrency1 = c1 == d.syield;

        PoolKey memory vernierPool = _key(c0, c1, d.hook);
        PoolKey memory basePool = _key(c0, c1, address(0));

        IPoolManager(poolManager).initialize(vernierPool, SQRT_PRICE_1_1);
        IPoolManager(poolManager).initialize(basePool, SQRT_PRICE_1_1);

        VernierParHook hook = VernierParHook(d.hook);
        hook.configurePool(vernierPool, IRateSource(d.source), MAX_RATE_APR_PIPS, yieldIsCurrency1);
        hook.setAttestor(vernierPool, IRateAttestor(d.attestor));
        hook.setTrustedRouter(d.lpRouter, true);

        _seedInitial(d, vernierPool, basePool);
    }

    /// An empty pool has nothing to trade against, so the first swap walks the price to
    /// the tick limit and pins it there permanently. Both pools are funded here so they
    /// are never reachable in that state.
    function _seedInitial(Deployment memory d, PoolKey memory vernierPool, PoolKey memory basePool) internal {
        MockERC20(d.usdc).mint(msg.sender, 1_000_000e18);
        MockERC20(d.syield).mint(msg.sender, 1_000_000e18);
        MockERC20(d.usdc).approve(d.lpRouter, type(uint256).max);
        MockERC20(d.syield).approve(d.lpRouter, type(uint256).max);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: INITIAL_LIQUIDITY,
            salt: 0
        });

        PoolModifyLiquidityTest(d.lpRouter).modifyLiquidity(vernierPool, params, "");
        PoolModifyLiquidityTest(d.lpRouter).modifyLiquidity(basePool, params, "");
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
}
