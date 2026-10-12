// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WillFolksEscrow} from "../src/WillFolksEscrow.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Despliegue local (Anvil): USDC de prueba + WillFolksEscrow con un atestador.
/// @dev Variables: PRIVATE_KEY y ESCROW_ATTESTOR.
contract DeployEscrowLocalScript is Script {
    function run() external returns (MockERC20 usdc, WillFolksEscrow escrow) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address attestor = vm.envAddress("ESCROW_ATTESTOR");

        vm.startBroadcast(deployerPk);
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        escrow = new WillFolksEscrow(IERC20(address(usdc)), vm.addr(deployerPk), 100e6, 1 days);
        escrow.setAttestor(attestor, true);
        vm.stopBroadcast();

        console2.log("=== Local Deployment Addresses ===");
        console2.log("USDC Mock:", address(usdc));
        console2.log("WillFolksEscrow:", address(escrow));
        console2.log("Attestor:", attestor);
    }
}
