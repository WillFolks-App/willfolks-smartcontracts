// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MockERC20} from "./MockERC20.sol";

contract MockAavePool {
    MockERC20 public immutable usdc;
    MockERC20 public immutable aToken;

    constructor(address usdc_, address aToken_) {
        usdc = MockERC20(usdc_);
        aToken = MockERC20(aToken_);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(asset == address(usdc), "ASSET");
        usdc.transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(usdc), "ASSET");
        aToken.burn(msg.sender, amount);
        usdc.transfer(to, amount);
        return amount;
    }

    function addYield(address beneficiary, uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        aToken.mint(beneficiary, amount);
    }
}
