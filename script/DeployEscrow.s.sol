// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WillFolksEscrow} from "../src/WillFolksEscrow.sol";

/// @notice Despliegue de WillFolksEscrow en una red real (Fuji).
/// @dev Variables: PRIVATE_KEY, USDC_ADDRESS, ESCROW_ATTESTOR y, opcionales,
///      ESCROW_OWNER, ESCROW_MAX_STAKE (unidades del token) y ESCROW_RESOLUTION_GRACE (segundos).
contract DeployEscrowScript is Script {
    function run() external returns (WillFolksEscrow escrow) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address usdc = vm.envAddress("USDC_ADDRESS");
        address attestor = vm.envAddress("ESCROW_ATTESTOR");
        address finalOwner = vm.envOr("ESCROW_OWNER", deployer);
        uint128 maxStake = uint128(vm.envOr("ESCROW_MAX_STAKE", uint256(25e6)));
        uint40 grace = uint40(vm.envOr("ESCROW_RESOLUTION_GRACE", uint256(7 days)));

        vm.startBroadcast(deployerPk);
        escrow = new WillFolksEscrow(IERC20(usdc), deployer, maxStake, grace);
        escrow.setAttestor(attestor, true);
        // Ownable2Step: el nuevo owner debe llamar a acceptOwnership().
        if (finalOwner != deployer) escrow.transferOwnership(finalOwner);
        vm.stopBroadcast();

        console2.log("=== WillFolksEscrow ===");
        console2.log("Chain id:", block.chainid);
        console2.log("USDC:", usdc);
        console2.log("Escrow:", address(escrow));
        console2.log("Attestor:", attestor);
        console2.log("Owner:", deployer);
        if (finalOwner != deployer) console2.log("Pending owner:", finalOwner);
        console2.log("Max stake:", maxStake);
        console2.log("Resolution grace (s):", grace);
    }
}
