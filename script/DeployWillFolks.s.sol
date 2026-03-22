// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {WillFolksSingleton} from "../src/WillFolksSingleton.sol";

contract DeployWillFolksScript is Script {
    function run() external returns (WillFolksSingleton singleton) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address aavePool = vm.envAddress("AAVE_POOL_ADDRESS");
        address aToken = vm.envAddress("A_TOKEN_ADDRESS");
        address developerWallet = vm.envAddress("DEVELOPER_WALLET");

        vm.startBroadcast(deployerPk);
        singleton = new WillFolksSingleton(usdc, aavePool, aToken, developerWallet);
        vm.stopBroadcast();

        console2.log("=== Avalanche Deployment ===");
        console2.log("USDC:", usdc);
        console2.log("Aave Pool:", aavePool);
        console2.log("aToken:", aToken);
        console2.log("Developer Wallet:", developerWallet);
        console2.log("WillFolksSingleton:", address(singleton));
    }
}
