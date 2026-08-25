// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Faucet} from "../src/periphery/Faucet.sol";

contract DeployFaucet is Script {
    function run() external {
        address usdc = vm.envAddress("VERNIER_USDC");
        address syield = vm.envAddress("VERNIER_SYIELD");

        vm.startBroadcast();
        Faucet faucet = new Faucet(usdc, syield);
        vm.stopBroadcast();

        console.log("Faucet:", address(faucet));
    }
}
