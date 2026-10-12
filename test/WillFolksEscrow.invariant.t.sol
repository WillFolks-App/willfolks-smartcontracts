// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WillFolksEscrow} from "../src/WillFolksEscrow.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @dev Ejecuta secuencias aleatorias de acciones válidas e inválidas sobre el escrow.
contract EscrowHandler is Test {
    uint256 internal constant INITIAL_BALANCE = 10_000e6;
    bytes32 internal constant EVIDENCE = keccak256("evidence");

    WillFolksEscrow public immutable escrow;
    MockERC20 public immutable usdc;
    uint256 internal immutable attestorPk;
    address internal immutable attestor;

    address[] public actors;
    uint256 public deposited;
    uint256 public returned;
    uint256 public resolvedCount;

    constructor(WillFolksEscrow escrow_, MockERC20 usdc_, uint256 attestorPk_) {
        escrow = escrow_;
        usdc = usdc_;
        attestorPk = attestorPk_;
        attestor = vm.addr(attestorPk_);

        for (uint256 i = 0; i < 4; i++) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            usdc.mint(actor, INITIAL_BALANCE);
            vm.prank(actor);
            usdc.approve(address(escrow), type(uint256).max);
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function initialBalance() external pure returns (uint256) {
        return INITIAL_BALANCE;
    }

    function create(uint256 actorSeed, uint128 stake, uint40 startIn, uint40 duration, uint16 lockDays) external {
        address actor = actors[actorSeed % actors.length];
        stake = uint128(bound(stake, 1, escrow.maxStake()));
        startIn = uint40(bound(startIn, 0, 3 days));
        duration = uint40(bound(duration, 1, 30 days));
        lockDays = uint16(bound(lockDays, 0, 90));
        if (usdc.balanceOf(actor) < stake) return;

        uint40 start = uint40(block.timestamp) + startIn;
        vm.prank(actor);
        escrow.createGoal(
            stake, start, start + duration, lockDays, WillFolksEscrow.GoalKind(actorSeed % 4), bytes32(actorSeed)
        );
        deposited += stake;
    }

    function resolve(uint256 goalSeed, bool success) external {
        uint256 goalId = _pick(goalSeed);
        if (goalId == 0) return;

        uint40 validUntil = uint40(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(attestorPk, escrow.resolutionDigest(goalId, success, EVIDENCE, validUntil));
        uint256 balanceBefore = usdc.balanceOf(address(escrow));
        try escrow.resolve(goalId, success, EVIDENCE, validUntil, attestor, abi.encodePacked(r, s, v)) {
            resolvedCount++;
            returned += balanceBefore - usdc.balanceOf(address(escrow));
        } catch {}
    }

    function claim(uint256 goalSeed) external {
        _exit(goalSeed, this.callClaim);
    }

    function reclaim(uint256 goalSeed) external {
        _exit(goalSeed, this.callReclaim);
    }

    function cancel(uint256 goalSeed) external {
        uint256 goalId = _pick(goalSeed);
        if (goalId == 0) return;
        uint256 balanceBefore = usdc.balanceOf(address(escrow));
        vm.prank(escrow.getGoal(goalId).creator);
        try escrow.cancel(goalId) {
            returned += balanceBefore - usdc.balanceOf(address(escrow));
        } catch {}
    }

    function warp(uint40 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 20 days));
    }

    function callClaim(uint256 goalId) external {
        escrow.claim(goalId);
    }

    function callReclaim(uint256 goalId) external {
        escrow.reclaim(goalId);
    }

    function _exit(uint256 goalSeed, function(uint256) external fn) internal {
        uint256 goalId = _pick(goalSeed);
        if (goalId == 0) return;
        uint256 balanceBefore = usdc.balanceOf(address(escrow));
        try fn(goalId) {
            returned += balanceBefore - usdc.balanceOf(address(escrow));
        } catch {}
    }

    function _pick(uint256 seed) internal view returns (uint256) {
        uint256 count = escrow.nextGoalId() - 1;
        return count == 0 ? 0 : (seed % count) + 1;
    }
}

contract WillFolksEscrowInvariantTest is Test {
    MockERC20 internal usdc;
    WillFolksEscrow internal escrow;
    EscrowHandler internal handler;

    function setUp() public {
        vm.warp(1_760_000_000);
        (address attestor, uint256 attestorPk) = makeAddrAndKey("attestor");
        address owner = makeAddr("owner");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        escrow = new WillFolksEscrow(IERC20(address(usdc)), owner, 100e6, 7 days);
        vm.prank(owner);
        escrow.setAttestor(attestor, true);

        handler = new EscrowHandler(escrow, usdc, attestorPk);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = EscrowHandler.create.selector;
        selectors[1] = EscrowHandler.resolve.selector;
        selectors[2] = EscrowHandler.claim.selector;
        selectors[3] = EscrowHandler.reclaim.selector;
        selectors[4] = EscrowHandler.cancel.selector;
        selectors[5] = EscrowHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev El contrato custodia exactamente lo que dice custodiar.
    function invariant_BalanceEqualsTotalLocked() public view {
        assertEq(usdc.balanceOf(address(escrow)), escrow.totalLocked());
    }

    /// @dev `totalLocked` es la suma de los stakes de metas activas o fallidas sin reclamar.
    function invariant_TotalLockedMatchesOpenGoals() public view {
        uint256 open;
        uint256 count = escrow.nextGoalId() - 1;
        for (uint256 id = 1; id <= count; id++) {
            WillFolksEscrow.Goal memory goal = escrow.getGoal(id);
            if (goal.state == WillFolksEscrow.GoalState.Active || goal.state == WillFolksEscrow.GoalState.Failed) {
                open += goal.stake;
            }
        }
        assertEq(open, escrow.totalLocked());
    }

    /// @dev Todo lo depositado está en el contrato o ya volvió; nada se pierde ni se crea.
    function invariant_DepositsAreConserved() public view {
        assertEq(handler.deposited(), handler.returned() + usdc.balanceOf(address(escrow)));
    }

    /// @dev El stake solo vuelve a su creador: nadie termina con más ni con menos de lo suyo.
    function invariant_EachActorKeepsTheirFunds() public view {
        uint256 actorCount = handler.actorsLength();
        uint256 count = escrow.nextGoalId() - 1;
        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actors(i);
            uint256 locked;
            for (uint256 id = 1; id <= count; id++) {
                WillFolksEscrow.Goal memory goal = escrow.getGoal(id);
                bool open =
                    goal.state == WillFolksEscrow.GoalState.Active || goal.state == WillFolksEscrow.GoalState.Failed;
                if (goal.creator == actor && open) locked += goal.stake;
            }
            assertEq(usdc.balanceOf(actor) + locked, handler.initialBalance());
        }
    }
}
