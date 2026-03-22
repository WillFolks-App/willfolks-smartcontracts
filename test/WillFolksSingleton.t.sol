// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {WillFolksSingleton} from "../src/WillFolksSingleton.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ALLOWANCE");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "BURN");
        balanceOf[from] -= amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "TO");
        require(balanceOf[from] >= amount, "BAL");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

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

contract WillFolksSingletonTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal aUsdc;
    MockAavePool internal pool;
    WillFolksSingleton internal singleton;

    uint256 internal constant USER_PK = 0xA11CE;
    uint256 internal constant AGENT_PK = 0xB0B;
    uint256 internal constant VERIFIER_PK = 0xC0DE;

    address internal user;
    address internal agent;
    address internal verifier;
    address internal devWallet;
    address internal winner;

    function setUp() public {
        user = vm.addr(USER_PK);
        agent = vm.addr(AGENT_PK);
        verifier = vm.addr(VERIFIER_PK);
        devWallet = makeAddr("devWallet");
        winner = makeAddr("winner");

        usdc = new MockERC20("Mock USDC", "USDC", 6);
        aUsdc = new MockERC20("Mock aUSDC", "aUSDC", 6);
        pool = new MockAavePool(address(usdc), address(aUsdc));
        singleton = new WillFolksSingleton(address(usdc), address(pool), address(aUsdc), devWallet);

        usdc.mint(user, 1_000_000e6);
        usdc.mint(verifier, 1_000_000e6);
        usdc.mint(address(this), 1_000_000e6);

        vm.prank(user);
        usdc.approve(address(singleton), type(uint256).max);

        vm.prank(verifier);
        usdc.approve(address(singleton), type(uint256).max);

        usdc.approve(address(pool), type(uint256).max);
    }

    function test_CreateAndResolvePersonalSuccess_WithYield() public {
        uint64 startAt = uint64(block.timestamp + 1 days);
        uint64 endAt = uint64(startAt + 30 days);

        WillFolksSingleton.CreateBaseParams memory base = WillFolksSingleton.CreateBaseParams({
            isGroup: false,
            participants: _singleParticipantArray(user),
            stakeAmount: 100e6,
            startAt: startAt,
            endAt: endAt,
            extraLockDays: 7,
            devTipPct: 10,
            kind: WillFolksSingleton.WilliamKind.IRL,
            payoutRecipient: user,
            localAgent: agent
        });

        bytes memory subtype = abi.encode("Prompt IA para validacion", _singleCIDArray("ipfs://evidence-1"));

        vm.prank(user);
        uint256 williamId = singleton.createWilliam(base, subtype);

        pool.addYield(address(singleton), 20e6);

        vm.warp(endAt + 1);

        bytes32 digest = _resolutionDigest(singleton, williamId, true, user, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AGENT_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 userBalanceBefore = usdc.balanceOf(user);
        singleton.resolvePersonalWilliam(williamId, true, sig);
        uint256 userBalanceAfter = usdc.balanceOf(user);

        assertGt(userBalanceAfter - userBalanceBefore, 100e6);

        (, , , , , uint128 shares, , , , , , , uint8 state,) = singleton.williams(williamId);
        assertEq(uint256(shares), 0);
        assertEq(uint256(state), uint256(WillFolksSingleton.WilliamState.Exito));
    }

    function test_PersonalFail_DevTip_AndClaimAfterSoftLock() public {
        uint64 startAt = uint64(block.timestamp + 1 days);
        uint64 endAt = uint64(startAt + 30 days);

        WillFolksSingleton.CreateBaseParams memory base = WillFolksSingleton.CreateBaseParams({
            isGroup: false,
            participants: _singleParticipantArray(user),
            stakeAmount: 100e6,
            startAt: startAt,
            endAt: endAt,
            extraLockDays: 5,
            devTipPct: 10,
            kind: WillFolksSingleton.WilliamKind.Alarma,
            payoutRecipient: user,
            localAgent: agent
        });

        bytes memory subtype = abi.encode(uint32(7 * 3600), uint8(0x7F), uint32(90));

        vm.prank(user);
        uint256 williamId = singleton.createWilliam(base, subtype);

        pool.addYield(address(singleton), 20e6);

        vm.warp(endAt + 1);
        bytes32 digest = _resolutionDigest(singleton, williamId, false, user, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AGENT_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 devBefore = usdc.balanceOf(devWallet);
        singleton.resolvePersonalWilliam(williamId, false, sig);
        uint256 devAfter = usdc.balanceOf(devWallet);

        assertEq(devAfter - devBefore, 10e6);

        vm.expectRevert();
        singleton.claimSoftFailFunds(williamId);

        vm.warp(block.timestamp + 5 days + 1);

        uint256 userBefore = usdc.balanceOf(user);
        singleton.claimSoftFailFunds(williamId);
        uint256 userAfter = usdc.balanceOf(user);

        assertGt(userAfter - userBefore, 100e6);
    }

    function test_GroupResolvePaysVerifierReward() public {
        uint64 startAt = uint64(block.timestamp + 1 days);
        uint64 endAt = uint64(startAt + 30 days);

        singleton.setMinVerifierStake(50e6);

        vm.prank(verifier);
        singleton.stakeAsVerifier(100e6);

        address[] memory participants = new address[](2);
        participants[0] = user;
        participants[1] = winner;

        WillFolksSingleton.CreateBaseParams memory base = WillFolksSingleton.CreateBaseParams({
            isGroup: true,
            participants: participants,
            stakeAmount: 100e6,
            startAt: startAt,
            endAt: endAt,
            extraLockDays: 7,
            devTipPct: 0,
            kind: WillFolksSingleton.WilliamKind.AppTimer,
            payoutRecipient: user,
            localAgent: address(0)
        });

        bytes memory subtype = abi.encode(keccak256("com.example.socialapp"), uint32(180));

        vm.prank(user);
        uint256 williamId = singleton.createWilliam(base, subtype);

        pool.addYield(address(singleton), 20e6);

        vm.warp(endAt + 1);
        bytes32 digest = _resolutionDigest(singleton, williamId, true, winner, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(VERIFIER_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 verifierBefore = usdc.balanceOf(verifier);
        uint256 winnerBefore = usdc.balanceOf(winner);

        singleton.resolveGroupWilliam(williamId, true, winner, sig);

        uint256 verifierAfter = usdc.balanceOf(verifier);
        uint256 winnerAfter = usdc.balanceOf(winner);

        assertGt(verifierAfter - verifierBefore, 0);
        assertGt(winnerAfter - winnerBefore, 100e6);
    }

    function _singleParticipantArray(address participant) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = participant;
    }

    function _singleCIDArray(string memory cid) internal pure returns (string[] memory arr) {
        arr = new string[](1);
        arr[0] = cid;
    }

    function _resolutionDigest(
        WillFolksSingleton target,
        uint256 williamId,
        bool success,
        address payoutRecipient,
        uint256 nonce
    ) internal view returns (bytes32) {
        bytes32 typeHash = keccak256(
            "ResolveWilliam(uint256 williamId,bool success,address payoutRecipient,uint256 nonce,uint256 chainId,address verifyingContract)"
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, williamId, success, payoutRecipient, nonce, block.chainid, address(target))
        );
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
    }
}
