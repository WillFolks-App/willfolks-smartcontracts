// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title WillFolksEscrow
/// @notice Escrow de compromisos (fase 1): el usuario bloquea USDC contra una meta y un
///         atestador autorizado firma el veredicto. Si cumple, recupera el stake; si falla,
///         el stake queda bloqueado `lockDays` más allá del fin de la meta y luego vuelve a él.
/// @dev Propiedades que este contrato garantiza:
///      - El stake solo puede salir hacia su creador. No hay función que lo envíe a otro lado.
///      - El owner administra atestadores, tope y pausa de creación; nunca toca fondos.
///      - Si ningún atestador resuelve, el creador recupera el stake pasado el plazo de gracia.
///      - La pausa solo detiene la creación de metas; resolver, reclamar y cancelar siguen activos.
contract WillFolksEscrow is Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    /// @notice Tipo de meta. Es informativo: la verificación ocurre fuera de la cadena.
    enum GoalKind {
        Alarm,
        AppTimer,
        Location,
        Proof
    }

    /// @notice Ciclo de vida de una meta.
    /// @dev `Active` es el único estado con fondos en disputa; `Failed` los mantiene bloqueados.
    enum GoalState {
        None,
        Active,
        Succeeded,
        Failed,
        Claimed,
        Expired,
        Cancelled
    }

    /// @dev Empaquetado en 3 slots: (creator, startAt, endAt, lockDays) | (stake, unlockAt, kind, state) | metadataHash.
    struct Goal {
        address creator;
        uint40 startAt;
        uint40 endAt;
        uint16 lockDays;
        uint128 stake;
        uint40 unlockAt;
        GoalKind kind;
        GoalState state;
        bytes32 metadataHash;
    }

    error ZeroAddress();
    error InvalidStake();
    error StakeAboveCap();
    error InvalidWindow();
    error LockTooLong();
    error InvalidGrace();
    error UnexpectedTransferAmount();
    error GoalNotActive();
    error GoalNotFailed();
    error NotCreator();
    error AlreadyStarted();
    error NotStarted();
    error TooEarlyForSuccess();
    error ResolutionWindowClosed();
    error ResolutionWindowOpen();
    error AttestorNotAuthorized();
    error SignatureExpired();
    error InvalidSignature();
    error StillLocked();
    error RenounceDisabled();

    event GoalCreated(
        uint256 indexed goalId,
        address indexed creator,
        GoalKind kind,
        uint128 stake,
        uint40 startAt,
        uint40 endAt,
        uint16 lockDays,
        bytes32 metadataHash
    );
    event GoalResolved(
        uint256 indexed goalId, bool indexed success, address indexed attestor, bytes32 evidenceHash, uint40 unlockAt
    );
    event GoalClaimed(uint256 indexed goalId, address indexed creator, uint128 amount);
    event GoalExpired(uint256 indexed goalId, address indexed creator, uint128 amount);
    event GoalCancelled(uint256 indexed goalId, address indexed creator, uint128 amount);
    event AttestorUpdated(address indexed attestor, bool authorized);
    event MaxStakeUpdated(uint128 previousMaxStake, uint128 newMaxStake);

    /// @notice Duración máxima de una meta.
    uint40 public constant MAX_DURATION = 365 days;
    /// @notice Tope del bloqueo extra por fallo, para que nadie quede atrapado indefinidamente.
    uint16 public constant MAX_LOCK_DAYS = 90;
    uint40 public constant MIN_RESOLUTION_GRACE = 1 days;
    uint40 public constant MAX_RESOLUTION_GRACE = 30 days;

    bytes32 public constant RESOLUTION_TYPEHASH =
        keccak256("Resolution(uint256 goalId,bool success,bytes32 evidenceHash,uint40 validUntil)");

    /// @notice Token del stake (USDC).
    IERC20 public immutable token;
    /// @notice Plazo tras `endAt` en el que un atestador aún puede resolver. Pasado ese plazo
    ///         solo queda `reclaim`, que devuelve el stake al creador.
    uint40 public immutable resolutionGrace;

    /// @notice Tope por meta. Bajo a propósito mientras el contrato no esté auditado.
    uint128 public maxStake;
    uint256 public nextGoalId = 1;
    /// @notice Suma de stakes que el contrato aún custodia (metas `Active` y `Failed`).
    uint256 public totalLocked;

    mapping(uint256 goalId => Goal) private _goals;
    mapping(address attestor => bool) public isAttestor;

    /// @param token_ Token del stake.
    /// @param owner_ Administrador de atestadores, tope y pausa. Debería ser un multisig.
    /// @param maxStake_ Tope inicial por meta, en unidades del token.
    /// @param resolutionGrace_ Plazo de gracia para resolver tras `endAt`.
    constructor(IERC20 token_, address owner_, uint128 maxStake_, uint40 resolutionGrace_)
        Ownable(owner_)
        EIP712("WillFolksEscrow", "1")
    {
        if (address(token_) == address(0)) revert ZeroAddress();
        if (maxStake_ == 0) revert InvalidStake();
        if (resolutionGrace_ < MIN_RESOLUTION_GRACE || resolutionGrace_ > MAX_RESOLUTION_GRACE) revert InvalidGrace();

        token = token_;
        maxStake = maxStake_;
        resolutionGrace = resolutionGrace_;
        emit MaxStakeUpdated(0, maxStake_);
    }

    // ---------------------------------------------------------------- metas

    /// @notice Crea una meta y bloquea `stake` del creador.
    /// @dev Un `startAt` pasado se ajusta al bloque actual: el reloj del teléfono y el de la
    ///      cadena no coinciden y la transacción puede minarse tarde.
    /// @param stake Monto a bloquear. Requiere `approve` previo.
    /// @param startAt Inicio de la meta. Antes de esta fecha el creador puede cancelar.
    /// @param endAt Fin de la meta. El éxito solo puede atestarse desde aquí.
    /// @param lockDays Días de bloqueo extra si falla, contados desde `endAt` o desde el
    ///        veredicto si llega después.
    /// @param kind Tipo de meta.
    /// @param metadataHash Hash de la configuración fuera de la cadena (hora, app, lugar, criterio).
    function createGoal(
        uint128 stake,
        uint40 startAt,
        uint40 endAt,
        uint16 lockDays,
        GoalKind kind,
        bytes32 metadataHash
    ) external whenNotPaused nonReentrant returns (uint256 goalId) {
        if (stake == 0) revert InvalidStake();
        if (stake > maxStake) revert StakeAboveCap();
        if (lockDays > MAX_LOCK_DAYS) revert LockTooLong();

        uint40 start = startAt < block.timestamp ? uint40(block.timestamp) : startAt;
        if (endAt <= start || endAt - start > MAX_DURATION) revert InvalidWindow();

        goalId = nextGoalId++;
        _goals[goalId] = Goal({
            creator: msg.sender,
            startAt: start,
            endAt: endAt,
            lockDays: lockDays,
            stake: stake,
            unlockAt: 0,
            kind: kind,
            state: GoalState.Active,
            metadataHash: metadataHash
        });
        totalLocked += stake;

        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), stake);
        // Rechaza tokens con comisión por transferencia: romperían la contabilidad 1:1.
        if (token.balanceOf(address(this)) - balanceBefore != stake) revert UnexpectedTransferAmount();

        emit GoalCreated(goalId, msg.sender, kind, stake, start, endAt, lockDays, metadataHash);
    }

    /// @notice Aplica el veredicto firmado por un atestador autorizado. Cualquiera puede enviarlo.
    /// @dev El fallo puede atestarse desde `startAt` (intentos agotados); el éxito solo desde
    ///      `endAt`. Ambos caducan en `endAt + resolutionGrace`.
    /// @param evidenceHash Hash del registro de evidencia y veredicto, para auditoría.
    /// @param validUntil Caducidad de la firma.
    /// @param attestor Firmante. Puede ser una cuenta de contrato (ERC-1271).
    function resolve(
        uint256 goalId,
        bool success,
        bytes32 evidenceHash,
        uint40 validUntil,
        address attestor,
        bytes calldata signature
    ) external nonReentrant {
        Goal storage goal = _goals[goalId];
        if (goal.state != GoalState.Active) revert GoalNotActive();
        if (block.timestamp < goal.startAt) revert NotStarted();
        if (success && block.timestamp < goal.endAt) revert TooEarlyForSuccess();
        if (block.timestamp > uint256(goal.endAt) + resolutionGrace) revert ResolutionWindowClosed();
        if (!isAttestor[attestor]) revert AttestorNotAuthorized();
        if (block.timestamp > validUntil) revert SignatureExpired();

        bytes32 digest = resolutionDigest(goalId, success, evidenceHash, validUntil);
        if (!SignatureChecker.isValidSignatureNow(attestor, digest, signature)) revert InvalidSignature();

        if (success) {
            goal.state = GoalState.Succeeded;
            emit GoalResolved(goalId, true, attestor, evidenceHash, 0);
            _payout(goal);
        } else {
            // El bloqueo cuenta desde el fin de la meta: fallar pronto nunca libera antes que cumplir.
            uint256 lockFrom = block.timestamp > goal.endAt ? block.timestamp : goal.endAt;
            uint40 unlockAt = uint40(lockFrom + uint256(goal.lockDays) * 1 days);
            goal.state = GoalState.Failed;
            goal.unlockAt = unlockAt;
            emit GoalResolved(goalId, false, attestor, evidenceHash, unlockAt);
        }
    }

    /// @notice Devuelve al creador el stake de una meta fallida cuando vence el bloqueo.
    function claim(uint256 goalId) external nonReentrant {
        Goal storage goal = _goals[goalId];
        if (goal.state != GoalState.Failed) revert GoalNotFailed();
        if (block.timestamp < goal.unlockAt) revert StillLocked();

        goal.state = GoalState.Claimed;
        emit GoalClaimed(goalId, goal.creator, goal.stake);
        _payout(goal);
    }

    /// @notice Salida de emergencia: si nadie resolvió dentro del plazo de gracia, el stake
    ///         vuelve al creador.
    function reclaim(uint256 goalId) external nonReentrant {
        Goal storage goal = _goals[goalId];
        if (goal.state != GoalState.Active) revert GoalNotActive();
        if (block.timestamp <= uint256(goal.endAt) + resolutionGrace) revert ResolutionWindowOpen();

        goal.state = GoalState.Expired;
        emit GoalExpired(goalId, goal.creator, goal.stake);
        _payout(goal);
    }

    /// @notice El creador cancela una meta que aún no empezó y recupera el stake.
    function cancel(uint256 goalId) external nonReentrant {
        Goal storage goal = _goals[goalId];
        if (goal.state != GoalState.Active) revert GoalNotActive();
        if (msg.sender != goal.creator) revert NotCreator();
        if (block.timestamp >= goal.startAt) revert AlreadyStarted();

        goal.state = GoalState.Cancelled;
        emit GoalCancelled(goalId, goal.creator, goal.stake);
        _payout(goal);
    }

    // ------------------------------------------------------- administración

    function setAttestor(address attestor, bool authorized) external onlyOwner {
        if (attestor == address(0)) revert ZeroAddress();
        isAttestor[attestor] = authorized;
        emit AttestorUpdated(attestor, authorized);
    }

    function setMaxStake(uint128 newMaxStake) external onlyOwner {
        if (newMaxStake == 0) revert InvalidStake();
        emit MaxStakeUpdated(maxStake, newMaxStake);
        maxStake = newMaxStake;
    }

    /// @notice Detiene la creación de metas nuevas. No afecta a las existentes.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Sin owner no se podrían rotar atestadores comprometidos.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ------------------------------------------------------------- lectura

    function getGoal(uint256 goalId) external view returns (Goal memory) {
        return _goals[goalId];
    }

    /// @notice Digest EIP-712 que el atestador debe firmar para un veredicto.
    function resolutionDigest(uint256 goalId, bool success, bytes32 evidenceHash, uint40 validUntil)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(RESOLUTION_TYPEHASH, goalId, success, evidenceHash, validUntil)));
    }

    // ------------------------------------------------------------- interno

    /// @dev Única salida de fondos del contrato: siempre hacia el creador de la meta.
    function _payout(Goal storage goal) private {
        uint128 amount = goal.stake;
        totalLocked -= amount;
        token.safeTransfer(goal.creator, amount);
    }
}
