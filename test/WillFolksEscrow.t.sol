// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {WillFolksEscrow} from "../src/WillFolksEscrow.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @dev Token que cobra 1% en cada transferencia.
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("Fee Token", "FEE", 6) {}

    function _transfer(address from, address to, uint256 amount) internal override {
        require(balanceOf[from] >= amount, "BAL");
        balanceOf[from] -= amount;
        balanceOf[to] += amount - amount / 100;
    }
}

/// @dev Atestador como cuenta de contrato: valida la firma de su dueño (ERC-1271).
contract ContractAttestor is IERC1271 {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        return ECDSA.recover(hash, signature) == signer ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

contract WillFolksEscrowTest is Test {
    uint128 internal constant MAX_STAKE = 100e6;
    uint40 internal constant GRACE = 7 days;
    uint128 internal constant STAKE = 25e6;
    bytes32 internal constant METADATA = keccak256("alarm 07:00 mon-fri");
    bytes32 internal constant EVIDENCE = keccak256("evidence");

    MockERC20 internal usdc;
    WillFolksEscrow internal escrow;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal relayer = makeAddr("relayer");
    address internal attestor;
    uint256 internal attestorPk;
    address internal stranger;
    uint256 internal strangerPk;

    event GoalCreated(
        uint256 indexed goalId,
        address indexed creator,
        WillFolksEscrow.GoalKind kind,
        uint128 stake,
        uint40 startAt,
        uint40 endAt,
        uint16 lockDays,
        bytes32 metadataHash
    );
    event GoalResolved(
        uint256 indexed goalId, bool indexed success, address indexed attestor, bytes32 evidenceHash, uint40 unlockAt
    );

    function setUp() public {
        vm.warp(1_760_000_000);
        (attestor, attestorPk) = makeAddrAndKey("attestor");
        (stranger, strangerPk) = makeAddrAndKey("stranger");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        escrow = new WillFolksEscrow(IERC20(address(usdc)), owner, MAX_STAKE, GRACE);

        vm.prank(owner);
        escrow.setAttestor(attestor, true);

        usdc.mint(user, 1_000e6);
        vm.prank(user);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ------------------------------------------------------------- helpers

    function _create(uint128 stake, uint40 startIn, uint40 duration, uint16 lockDays) internal returns (uint256) {
        uint40 start = uint40(block.timestamp) + startIn;
        vm.prank(user);
        return escrow.createGoal(stake, start, start + duration, lockDays, WillFolksEscrow.GoalKind.Alarm, METADATA);
    }

    function _sign(uint256 pk, uint256 goalId, bool success, uint40 validUntil) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, escrow.resolutionDigest(goalId, success, EVIDENCE, validUntil));
        return abi.encodePacked(r, s, v);
    }

    function _resolve(uint256 goalId, bool success) internal {
        uint40 validUntil = uint40(block.timestamp + 1 hours);
        escrow.resolve(goalId, success, EVIDENCE, validUntil, attestor, _sign(attestorPk, goalId, success, validUntil));
    }

    function _state(uint256 goalId) internal view returns (WillFolksEscrow.GoalState) {
        return escrow.getGoal(goalId).state;
    }

    // ------------------------------------------------------------ creación

    function test_Create_LocksStakeAndStoresGoal() public {
        uint40 start = uint40(block.timestamp) + 1 hours;

        vm.expectEmit(true, true, false, true);
        emit GoalCreated(1, user, WillFolksEscrow.GoalKind.Location, STAKE, start, start + 7 days, 3, METADATA);
        vm.prank(user);
        uint256 id = escrow.createGoal(STAKE, start, start + 7 days, 3, WillFolksEscrow.GoalKind.Location, METADATA);

        WillFolksEscrow.Goal memory goal = escrow.getGoal(id);
        assertEq(id, 1);
        assertEq(goal.creator, user);
        assertEq(goal.stake, STAKE);
        assertEq(goal.startAt, start);
        assertEq(goal.endAt, start + 7 days);
        assertEq(goal.lockDays, 3);
        assertEq(uint8(goal.kind), uint8(WillFolksEscrow.GoalKind.Location));
        assertEq(uint8(goal.state), uint8(WillFolksEscrow.GoalState.Active));
        assertEq(goal.metadataHash, METADATA);
        assertEq(usdc.balanceOf(address(escrow)), STAKE);
        assertEq(escrow.totalLocked(), STAKE);
        assertEq(usdc.balanceOf(user), 1_000e6 - STAKE);
    }

    function test_Create_ClampsPastStartToNow() public {
        uint40 nowTs = uint40(block.timestamp);
        vm.prank(user);
        uint256 id =
            escrow.createGoal(STAKE, nowTs - 1 days, nowTs + 1 days, 0, WillFolksEscrow.GoalKind.Alarm, METADATA);
        assertEq(escrow.getGoal(id).startAt, nowTs);
    }

    function test_Create_RevertsOnInvalidInput() public {
        uint40 nowTs = uint40(block.timestamp);
        vm.startPrank(user);

        vm.expectRevert(WillFolksEscrow.InvalidStake.selector);
        escrow.createGoal(0, nowTs, nowTs + 1 days, 0, WillFolksEscrow.GoalKind.Alarm, METADATA);

        vm.expectRevert(WillFolksEscrow.StakeAboveCap.selector);
        escrow.createGoal(MAX_STAKE + 1, nowTs, nowTs + 1 days, 0, WillFolksEscrow.GoalKind.Alarm, METADATA);

        vm.expectRevert(WillFolksEscrow.LockTooLong.selector);
        escrow.createGoal(STAKE, nowTs, nowTs + 1 days, 91, WillFolksEscrow.GoalKind.Alarm, METADATA);

        vm.expectRevert(WillFolksEscrow.InvalidWindow.selector);
        escrow.createGoal(STAKE, nowTs + 1 days, nowTs + 1 days, 0, WillFolksEscrow.GoalKind.Alarm, METADATA);

        // Un fin ya pasado no deja ventana tras ajustar el inicio.
        vm.expectRevert(WillFolksEscrow.InvalidWindow.selector);
        escrow.createGoal(STAKE, nowTs - 2 days, nowTs - 1 days, 0, WillFolksEscrow.GoalKind.Alarm, METADATA);

        vm.expectRevert(WillFolksEscrow.InvalidWindow.selector);
        escrow.createGoal(STAKE, nowTs, nowTs + 365 days + 1, 0, WillFolksEscrow.GoalKind.Alarm, METADATA);

        vm.stopPrank();
        assertEq(escrow.totalLocked(), 0);
    }

    function test_Create_RejectsFeeOnTransferToken() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        WillFolksEscrow feeEscrow = new WillFolksEscrow(IERC20(address(fee)), owner, MAX_STAKE, GRACE);
        fee.mint(user, STAKE);

        vm.startPrank(user);
        fee.approve(address(feeEscrow), STAKE);
        uint40 nowTs = uint40(block.timestamp);
        vm.expectRevert(WillFolksEscrow.UnexpectedTransferAmount.selector);
        feeEscrow.createGoal(STAKE, nowTs, nowTs + 1 days, 0, WillFolksEscrow.GoalKind.Alarm, METADATA);
        vm.stopPrank();
    }

    function test_Constructor_ValidatesArguments() public {
        vm.expectRevert(WillFolksEscrow.ZeroAddress.selector);
        new WillFolksEscrow(IERC20(address(0)), owner, MAX_STAKE, GRACE);

        vm.expectRevert(WillFolksEscrow.InvalidStake.selector);
        new WillFolksEscrow(IERC20(address(usdc)), owner, 0, GRACE);

        vm.expectRevert(WillFolksEscrow.InvalidGrace.selector);
        new WillFolksEscrow(IERC20(address(usdc)), owner, MAX_STAKE, 1 days - 1);

        vm.expectRevert(WillFolksEscrow.InvalidGrace.selector);
        new WillFolksEscrow(IERC20(address(usdc)), owner, MAX_STAKE, 30 days + 1);
    }

    // ---------------------------------------------------------- resolución

    function test_Resolve_SuccessReturnsStake() public {
        uint256 id = _create(STAKE, 0, 7 days, 5);
        vm.warp(block.timestamp + 7 days);

        vm.expectEmit(true, true, true, true);
        emit GoalResolved(id, true, attestor, EVIDENCE, 0);
        vm.prank(relayer);
        _resolve(id, true);

        assertEq(uint8(_state(id)), uint8(WillFolksEscrow.GoalState.Succeeded));
        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(usdc.balanceOf(relayer), 0);
        assertEq(escrow.totalLocked(), 0);
    }

    function test_Resolve_SuccessBeforeEndReverts() public {
        uint256 id = _create(STAKE, 0, 7 days, 5);
        vm.warp(block.timestamp + 7 days - 1);

        uint40 validUntil = uint40(block.timestamp + 1 hours);
        bytes memory sig = _sign(attestorPk, id, true, validUntil);
        vm.expectRevert(WillFolksEscrow.TooEarlyForSuccess.selector);
        escrow.resolve(id, true, EVIDENCE, validUntil, attestor, sig);
    }

    function test_Resolve_FailLocksThenClaimReturnsStake() public {
        uint256 id = _create(STAKE, 0, 7 days, 5);
        vm.warp(block.timestamp + 2 days);
        uint40 failedAt = uint40(block.timestamp);

        _resolve(id, false);

        WillFolksEscrow.Goal memory goal = escrow.getGoal(id);
        assertEq(uint8(goal.state), uint8(WillFolksEscrow.GoalState.Failed));
        assertEq(goal.unlockAt, failedAt + 5 days);
        assertEq(usdc.balanceOf(user), 1_000e6 - STAKE);
        assertEq(escrow.totalLocked(), STAKE);

        vm.warp(failedAt + 5 days - 1);
        vm.expectRevert(WillFolksEscrow.StillLocked.selector);
        escrow.claim(id);

        vm.warp(failedAt + 5 days);
        vm.prank(relayer);
        escrow.claim(id);

        assertEq(uint8(_state(id)), uint8(WillFolksEscrow.GoalState.Claimed));
        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(usdc.balanceOf(relayer), 0);
        assertEq(escrow.totalLocked(), 0);

        vm.expectRevert(WillFolksEscrow.GoalNotFailed.selector);
        escrow.claim(id);
    }

    function test_Resolve_FailWithoutLockIsClaimableAtOnce() public {
        uint256 id = _create(STAKE, 0, 7 days, 0);
        vm.warp(block.timestamp + 1 days);
        _resolve(id, false);
        escrow.claim(id);
        assertEq(usdc.balanceOf(user), 1_000e6);
    }

    function test_Resolve_FailBeforeStartReverts() public {
        uint256 id = _create(STAKE, 1 days, 7 days, 5);

        uint40 validUntil = uint40(block.timestamp + 1 hours);
        bytes memory sig = _sign(attestorPk, id, false, validUntil);
        vm.expectRevert(WillFolksEscrow.NotStarted.selector);
        escrow.resolve(id, false, EVIDENCE, validUntil, attestor, sig);
    }

    function test_Resolve_TwiceReverts() public {
        uint256 id = _create(STAKE, 0, 7 days, 5);
        vm.warp(block.timestamp + 7 days);
        _resolve(id, true);

        uint40 validUntil = uint40(block.timestamp + 1 hours);
        bytes memory sig = _sign(attestorPk, id, false, validUntil);
        vm.expectRevert(WillFolksEscrow.GoalNotActive.selector);
        escrow.resolve(id, false, EVIDENCE, validUntil, attestor, sig);
    }

    function test_Resolve_UnknownGoalReverts() public {
        uint40 validUntil = uint40(block.timestamp + 1 hours);
        bytes memory sig = _sign(attestorPk, 99, true, validUntil);
        vm.expectRevert(WillFolksEscrow.GoalNotActive.selector);
        escrow.resolve(99, true, EVIDENCE, validUntil, attestor, sig);
    }

    // --------------------------------------------------------------- firmas

    /// @dev El creador no puede firmarse el éxito: su llave no está autorizada.
    function test_Signature_CreatorCannotSelfAttest() public {
        (address self, uint256 selfPk) = makeAddrAndKey("self");
        usdc.mint(self, STAKE);
        vm.startPrank(self);
        usdc.approve(address(escrow), STAKE);
        uint40 nowTs = uint40(block.timestamp);
        uint256 id = escrow.createGoal(STAKE, nowTs, nowTs + 1 days, 5, WillFolksEscrow.GoalKind.Alarm, METADATA);
        vm.stopPrank();

        vm.warp(nowTs + 1 days);
        uint40 validUntil = uint40(block.timestamp + 1 hours);
        bytes memory sig = _sign(selfPk, id, true, validUntil);
        vm.expectRevert(WillFolksEscrow.AttestorNotAuthorized.selector);
        escrow.resolve(id, true, EVIDENCE, validUntil, self, sig);
    }

    function test_Signature_WrongSignerForAuthorizedAttestorReverts() public {
        uint256 id = _create(STAKE, 0, 7 days, 5);
        vm.warp(block.timestamp + 7 days);

        uint40 validUntil = uint40(block.timestamp + 1 hours);
        bytes memory sig = _sign(strangerPk, id, true, validUntil);
        vm.expectRevert(WillFolksEscrow.InvalidSignature.selector);
        escrow.resolve(id, true, EVIDENCE, validUntil, attestor, sig);
    }

    function test_Signature_RevokedAttestorReverts() public {
        uint256 id = _create(STAKE, 0, 7 days, 5);
        vm.warp(block.timestamp + 7 days);
        uint40 validUntil = uint40(block.timestamp + 1 hours);
        bytes memory sig = _sign(attestorPk, id, true, validUntil);

        vm.prank(owner);
        escrow.setAttestor(attestor, false);

        vm.expectRevert(WillFolksEscrow.AttestorNotAuthorized.selector);
        escrow.resolve(id, true, EVIDENCE, validUntil, attestor, sig);
    }

    function test_Signature_CannotBeReusedForAnotherGoalOrVerdict() public {
        uint256 first = _create(STAKE, 0, 7 days, 5);
        uint256 second = _create(STAKE, 0, 7 days, 5);
        vm.warp(block.timestamp + 7 days);
        uint40 validUntil = uint40(block.timestamp + 1 hours);

        bytes memory successForFirst = _sign(attestorPk, first, true, validUntil);
        vm.expectRevert(WillFolksEscrow.InvalidSignature.selector);
        escrow.resolve(second, true, EVIDENCE, validUntil, attestor, successForFirst);

        bytes memory failForFirst = _sign(attestorPk, first, false, validUntil);
        vm.expectRevert(WillFolksEscrow.InvalidSignature.selector);
        escrow.resolve(first, true, EVIDENCE, validUntil, attestor, failForFirst);

        // Cambiar la evidencia o la caducidad invalida la firma.
        vm.expectRevert(WillFolksEscrow.InvalidSignature.selector);
        escrow.resolve(first, true, keccak256("other"), validUntil, attestor, successForFirst);
        vm.expectRevert(WillFolksEscrow.InvalidSignature.selector);
        escrow.resolve(first, true, EVIDENCE, validUntil + 1, attestor, successForFirst);
    }

    function test_Signature_ExpiredReverts() public {
        uint256 id = _create(STAKE, 0, 7 days, 5);
        vm.warp(block.timestamp + 7 days);
        uint40 validUntil = uint40(block.timestamp + 1 hours);
        bytes memory sig = _sign(attestorPk, id, true, validUntil);

        vm.warp(uint256(validUntil) + 1);
        vm.expectRevert(WillFolksEscrow.SignatureExpired.selector);
        escrow.resolve(id, true, EVIDENCE, validUntil, attestor, sig);
    }

    function test_Signature_NotValidOnAnotherEscrow() public {
        WillFolksEscrow other = new WillFolksEscrow(IERC20(address(usdc)), owner, MAX_STAKE, GRACE);
        vm.prank(owner);
        other.setAttestor(attestor, true);
        vm.prank(user);
        usdc.approve(address(other), type(uint256).max);

        uint40 nowTs = uint40(block.timestamp);
        uint256 id = _create(STAKE, 0, 7 days, 5);
        vm.prank(user);
        uint256 otherId = other.createGoal(STAKE, nowTs, nowTs + 7 days, 5, WillFolksEscrow.GoalKind.Alarm, METADATA);
        assertEq(id, otherId);

        vm.warp(nowTs + 7 days);
        uint40 validUntil = uint40(block.timestamp + 1 hours);
        bytes memory sig = _sign(attestorPk, id, true, validUntil);
        vm.expectRevert(WillFolksEscrow.InvalidSignature.selector);
        other.resolve(otherId, true, EVIDENCE, validUntil, attestor, sig);
    }

    function test_Signature_NotValidOnAnotherChain() public {
        uint256 id = _create(STAKE, 0, 7 days, 5);
        vm.warp(block.timestamp + 7 days);
        uint40 validUntil = uint40(block.timestamp + 1 hours);
        bytes memory sig = _sign(attestorPk, id, true, validUntil);

        vm.chainId(43114);
        vm.expectRevert(WillFolksEscrow.InvalidSignature.selector);
        escrow.resolve(id, true, EVIDENCE, validUntil, attestor, sig);
    }

    /// @dev El digest se puede reconstruir fuera del contrato con el dominio EIP-712 estándar.
    function test_Signature_DigestMatchesEip712Spec() public view {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("WillFolksEscrow"),
                keccak256("1"),
                block.chainid,
                address(escrow)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Resolution(uint256 goalId,bool success,bytes32 evidenceHash,uint40 validUntil)"),
                uint256(7),
                true,
                EVIDENCE,
                uint40(1_800_000_000)
            )
        );
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        assertEq(escrow.resolutionDigest(7, true, EVIDENCE, 1_800_000_000), expected);
    }

    function test_Signature_ContractAttestorErc1271() public {
        ContractAttestor account = new ContractAttestor(stranger);
        vm.prank(owner);
        escrow.setAttestor(address(account), true);

        uint256 id = _create(STAKE, 0, 7 days, 5);
        vm.warp(block.timestamp + 7 days);
        uint40 validUntil = uint40(block.timestamp + 1 hours);

        bytes memory bad = _sign(attestorPk, id, true, validUntil);
        vm.expectRevert(WillFolksEscrow.InvalidSignature.selector);
        escrow.resolve(id, true, EVIDENCE, validUntil, address(account), bad);

        escrow.resolve(id, true, EVIDENCE, validUntil, address(account), _sign(strangerPk, id, true, validUntil));
        assertEq(usdc.balanceOf(user), 1_000e6);
    }

    // ------------------------------------------- salida de emergencia y cancelación

    function test_Reclaim_OnlyAfterGrace() public {
        uint256 id = _create(STAKE, 0, 7 days, 5);
        uint256 end = block.timestamp + 7 days;

        vm.warp(end + GRACE);
        vm.expectRevert(WillFolksEscrow.ResolutionWindowOpen.selector);
        escrow.reclaim(id);
        // En el último segundo de gracia el atestador todavía puede resolver.
        uint256 snapshot = vm.snapshotState();
        _resolve(id, false);
        vm.revertToState(snapshot);

        vm.warp(end + GRACE + 1);
        uint40 validUntil = uint40(block.timestamp + 1 hours);
        bytes memory sig = _sign(attestorPk, id, false, validUntil);
        vm.expectRevert(WillFolksEscrow.ResolutionWindowClosed.selector);
        escrow.resolve(id, false, EVIDENCE, validUntil, attestor, sig);

        vm.prank(relayer);
        escrow.reclaim(id);
        assertEq(uint8(_state(id)), uint8(WillFolksEscrow.GoalState.Expired));
        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(usdc.balanceOf(relayer), 0);

        vm.expectRevert(WillFolksEscrow.GoalNotActive.selector);
        escrow.reclaim(id);
    }

    function test_Cancel_OnlyCreatorBeforeStart() public {
        uint256 id = _create(STAKE, 1 days, 7 days, 5);

        vm.prank(stranger);
        vm.expectRevert(WillFolksEscrow.NotCreator.selector);
        escrow.cancel(id);

        vm.prank(user);
        escrow.cancel(id);
        assertEq(uint8(_state(id)), uint8(WillFolksEscrow.GoalState.Cancelled));
        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(escrow.totalLocked(), 0);

        uint256 started = _create(STAKE, 1 days, 7 days, 5);
        vm.warp(block.timestamp + 1 days);
        vm.prank(user);
        vm.expectRevert(WillFolksEscrow.AlreadyStarted.selector);
        escrow.cancel(started);
    }

    // ------------------------------------------------------- administración

    function test_Admin_OnlyOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.setAttestor(stranger, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.setMaxStake(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.pause();
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(WillFolksEscrow.ZeroAddress.selector);
        escrow.setAttestor(address(0), true);
        vm.expectRevert(WillFolksEscrow.InvalidStake.selector);
        escrow.setMaxStake(0);
        vm.expectRevert(WillFolksEscrow.RenounceDisabled.selector);
        escrow.renounceOwnership();

        escrow.setMaxStake(10e6);
        vm.stopPrank();
        assertEq(escrow.maxStake(), 10e6);

        uint40 nowTs = uint40(block.timestamp);
        vm.prank(user);
        vm.expectRevert(WillFolksEscrow.StakeAboveCap.selector);
        escrow.createGoal(STAKE, nowTs, nowTs + 1 days, 0, WillFolksEscrow.GoalKind.Alarm, METADATA);
    }

    function test_Admin_OwnershipTransferIsTwoStep() public {
        vm.prank(owner);
        escrow.transferOwnership(stranger);
        assertEq(escrow.owner(), owner);

        vm.prank(stranger);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), stranger);
    }

    /// @dev La pausa frena metas nuevas pero nunca retiene fondos de las existentes.
    function test_Pause_BlocksCreationButNotExits() public {
        uint256 toSucceed = _create(STAKE, 0, 7 days, 5);
        uint256 toFail = _create(STAKE, 0, 7 days, 0);
        uint256 toExpire = _create(STAKE, 0, 7 days, 5);
        uint256 toCancel = _create(STAKE, 30 days, 7 days, 5);

        vm.prank(owner);
        escrow.pause();

        uint40 nowTs = uint40(block.timestamp);
        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.createGoal(STAKE, nowTs, nowTs + 1 days, 0, WillFolksEscrow.GoalKind.Alarm, METADATA);

        vm.prank(user);
        escrow.cancel(toCancel);
        _resolve(toFail, false);
        escrow.claim(toFail);
        vm.warp(block.timestamp + 7 days);
        _resolve(toSucceed, true);
        vm.warp(block.timestamp + GRACE + 1);
        escrow.reclaim(toExpire);

        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(escrow.totalLocked(), 0);
    }

    // ----------------------------------------------------------------- fuzz

    function testFuzz_SuccessReturnsExactStake(uint128 stake, uint40 duration, uint16 lockDays, uint40 lateBy) public {
        stake = uint128(bound(stake, 1, MAX_STAKE));
        duration = uint40(bound(duration, 1, 365 days));
        lockDays = uint16(bound(lockDays, 0, 90));
        lateBy = uint40(bound(lateBy, 0, GRACE));

        uint256 id = _create(stake, 0, duration, lockDays);
        assertEq(usdc.balanceOf(address(escrow)), stake);

        vm.warp(block.timestamp + duration + lateBy);
        _resolve(id, true);

        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(escrow.totalLocked(), 0);
    }

    function testFuzz_FailLocksExactlyLockDays(uint128 stake, uint40 duration, uint16 lockDays, uint40 failAfter)
        public
    {
        stake = uint128(bound(stake, 1, MAX_STAKE));
        duration = uint40(bound(duration, 1, 365 days));
        lockDays = uint16(bound(lockDays, 1, 90));
        failAfter = uint40(bound(failAfter, 0, duration + GRACE));

        uint256 id = _create(stake, 0, duration, lockDays);
        vm.warp(block.timestamp + failAfter);
        uint256 failedAt = block.timestamp;
        _resolve(id, false);

        vm.warp(failedAt + uint256(lockDays) * 1 days - 1);
        vm.expectRevert(WillFolksEscrow.StillLocked.selector);
        escrow.claim(id);
        assertEq(usdc.balanceOf(user), 1_000e6 - stake);

        vm.warp(failedAt + uint256(lockDays) * 1 days);
        escrow.claim(id);
        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(escrow.totalLocked(), 0);
    }

    /// @dev Sin atestador, el stake siempre es recuperable pasado el plazo de gracia.
    function testFuzz_UnresolvedGoalIsAlwaysReclaimable(uint128 stake, uint40 startIn, uint40 duration, uint40 waited)
        public
    {
        stake = uint128(bound(stake, 1, MAX_STAKE));
        startIn = uint40(bound(startIn, 0, 30 days));
        duration = uint40(bound(duration, 1, 365 days));
        waited = uint40(bound(waited, 1, 3650 days));

        uint256 id = _create(stake, startIn, duration, 90);
        vm.prank(owner);
        escrow.setAttestor(attestor, false);

        vm.warp(block.timestamp + startIn + duration + GRACE + waited);
        escrow.reclaim(id);
        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testFuzz_ArbitrarySignerIsRejected(uint256 pk, bool success) public {
        pk = bound(pk, 1, 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140);
        vm.assume(pk != attestorPk);

        uint256 id = _create(STAKE, 0, 7 days, 5);
        vm.warp(block.timestamp + 7 days);
        uint40 validUntil = uint40(block.timestamp + 1 hours);
        bytes memory sig = _sign(pk, id, success, validUntil);

        vm.expectRevert(WillFolksEscrow.InvalidSignature.selector);
        escrow.resolve(id, success, EVIDENCE, validUntil, attestor, sig);
        vm.expectRevert(WillFolksEscrow.AttestorNotAuthorized.selector);
        escrow.resolve(id, success, EVIDENCE, validUntil, vm.addr(pk), sig);
    }

    function testFuzz_GarbageSignatureIsRejected(bytes calldata signature) public {
        uint256 id = _create(STAKE, 0, 7 days, 5);
        vm.warp(block.timestamp + 7 days);
        uint40 validUntil = uint40(block.timestamp + 1 hours);

        vm.expectRevert(WillFolksEscrow.InvalidSignature.selector);
        escrow.resolve(id, true, EVIDENCE, validUntil, attestor, signature);
    }
}
