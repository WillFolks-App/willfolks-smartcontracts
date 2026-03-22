// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {WillFolksSingleton} from "../src/WillFolksSingleton.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";

contract DeployWillFolksLocalScript is Script {
    function run() external returns (WillFolksSingleton singleton) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPk);

        MockERC20 usdc = new MockERC20("Mock USDC", "USDC", 6);
        MockERC20 aUsdc = new MockERC20("Mock aUSDC", "aUSDC", 6);
        MockAavePool pool = new MockAavePool(address(usdc), address(aUsdc));

        address developerWallet = vm.addr(deployerPk);
        singleton = new WillFolksSingleton(address(usdc), address(pool), address(aUsdc), developerWallet);

        vm.stopBroadcast();

        console2.log("=== Local Deployment Addresses ===");
        console2.log("USDC Mock:", address(usdc));
        console2.log("aUSDC Mock:", address(aUsdc));
        console2.log("Aave Pool Mock:", address(pool));
        console2.log("WillFolksSingleton:", address(singleton));
    }
}
