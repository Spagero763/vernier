// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VernierHook} from "../src/VernierHook.sol";
import {ERC4626RateSource} from "../src/adapters/ERC4626RateSource.sol";
import {IRateSource} from "../src/interfaces/IRateSource.sol";
import {MockYieldVault} from "../test/mocks/MockYieldVault.sol";

contract Deploy is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        address poolManager = vm.envOr("POOL_MANAGER", UNICHAIN_SEPOLIA_POOL_MANAGER);

        vm.startBroadcast();

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(VernierHook).creationCode, abi.encode(poolManager));
        VernierHook hook = new VernierHook{salt: salt}(IPoolManager(poolManager));
        require(address(hook) == hookAddr, "hook address mismatch");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 18);
        MockERC20 syield = new MockERC20("Staked USD", "sUSD", 18);
        MockYieldVault vault = new MockYieldVault();
        ERC4626RateSource source = new ERC4626RateSource(address(vault));

        (Currency c0, Currency c1) = address(usdc) < address(syield)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(syield)))
            : (Currency.wrap(address(syield)), Currency.wrap(address(usdc)));

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        IPoolManager(poolManager).initialize(key, SQRT_PRICE_1_1);

        hook.configurePool(key, IRateSource(address(source)), 50_000, 100_000, Currency.unwrap(c1) == address(syield));

        vm.stopBroadcast();

        console.log("PoolManager :", poolManager);
        console.log("VernierHook   :", address(hook));
        console.log("USDC        :", address(usdc));
        console.log("sYIELD      :", address(syield));
        console.log("Vault       :", address(vault));
        console.log("RateSource  :", address(source));
    }
}
