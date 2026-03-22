// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IAavePoolLike {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

abstract contract ReentrancyGuardLite {
    uint256 private _reentrancyStatus;

    error ReentrancyDetected();

    modifier nonReentrant() {
        if (_reentrancyStatus == 2) revert ReentrancyDetected();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    constructor() {
        _reentrancyStatus = 1;
    }
}

abstract contract OwnableLite {
    address public owner;

    error NotOwner();
    error ZeroAddress();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

contract WillFolksSingleton is ReentrancyGuardLite, OwnableLite {
    /// @notice Estados de ciclo de vida del reto WilliAm.
    /// @dev Se almacena como uint8 en el struct principal para reducir costo de storage.
    enum WilliamState {
        Active,
        Exito,
        Fallido,
        PendienteVerificacion
    }

    /// @notice Subtipos de reto soportados por el protocolo.
    /// @dev El detalle de cada subtipo se guarda en mappings separados para no inflar el struct base.
    enum WilliamKind {
        IRL,
        Alarma,
        AppTimer
    }

    /// @notice Struct base, optimizado para minimizar escrituras y lecturas en storage.
    /// @dev Se usan tipos pequeños (uint64/32/16/8) y packing para reducir gas en SSTORE.
    struct William {
        address creator;
        address payoutRecipient;
        address localAgent;
        address verifier;
        uint128 principal;
        uint128 shares;
        uint64 startAt;
        uint64 endAt;
        uint64 unlockAt;
        uint32 extraLockDays;
        uint16 devTipPct;
        uint8 kind;
        uint8 state;
        bool isGroup;
    }

    struct CreateBaseParams {
        bool isGroup;
        address[] participants;
        uint128 stakeAmount;
        uint64 startAt;
        uint64 endAt;
        uint32 extraLockDays;
        uint16 devTipPct;
        WilliamKind kind;
        address payoutRecipient;
        address localAgent;
    }

    struct AlarmData {
        uint32 targetSecondOfDay;
        uint8 activeDaysMask;
        uint32 maxReactionSeconds;
    }

    struct AppTimerData {
        bytes32 appId;
        uint32 maxMinutesPerWeek;
    }

    struct ResolutionResult {
        uint256 grossPosition;
        uint256 tipToDeveloper;
        uint256 verifierReward;
        uint256 payoutToUser;
    }

    error InvalidAmount();
    error InvalidDates();
    error InvalidTipPct();
    error InvalidParticipants();
    error InvalidSubtypeData();
    error InvalidState();
    error InvalidRecipient();
    error InvalidWinner();
    error InvalidSignatureLength();
    error InvalidSignatureV();
    error InvalidSignatureS();
    error InvalidSigner();
    error NotPersonal();
    error NotGroup();
    error VerificationTooEarly();
    error VerifierNotAllowed();
    error FundsStillLocked();
    error AlreadyClaimed();
    error TransferFailed();

    event WilliamCreated(
        uint256 indexed williamId,
        address indexed creator,
        bool indexed isGroup,
        uint8 kind,
        uint128 principal,
        uint64 startAt,
        uint64 endAt,
        uint32 extraLockDays,
        uint16 devTipPct,
        address payoutRecipient,
        address localAgent
    );
    event WilliamParticipants(uint256 indexed williamId, address[] participants);
    event WilliamIRLMetadata(uint256 indexed williamId, string prompt, string[] evidenceCids);
    event WilliamAlarmMetadata(
        uint256 indexed williamId,
        uint32 targetSecondOfDay,
        uint8 activeDaysMask,
        uint32 maxReactionSeconds
    );
    event WilliamAppTimerMetadata(uint256 indexed williamId, bytes32 appId, uint32 maxMinutesPerWeek);
    event WilliamResolved(
        uint256 indexed williamId,
        uint8 indexed finalState,
        bool successVerdict,
        address indexed resolverSigner,
        uint256 grossPosition,
        uint256 tipToDeveloper,
        uint256 verifierReward,
        uint256 payoutToUser,
        uint64 unlockAt
    );
    event SoftFailClaimed(uint256 indexed williamId, address indexed recipient, uint256 amount);
    event VerifierStaked(address indexed verifier, uint256 amount);
    event VerifierUnstaked(address indexed verifier, uint256 amount);
    event VerifierPermissionUpdated(address indexed verifier, bool allowed);
    event DefaultLocalAgentUpdated(address indexed scaOwner, address indexed agent);
    event DeveloperWalletUpdated(address indexed previousWallet, address indexed newWallet);
    event MinVerifierStakeUpdated(uint256 previousAmount, uint256 newAmount);
    event GroupVerifierFeeBpsUpdated(uint16 previousFeeBps, uint16 newFeeBps);

    bytes32 private constant RESOLUTION_TYPEHASH = keccak256(
        "ResolveWilliam(uint256 williamId,bool success,address payoutRecipient,uint256 nonce,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant SECP256K1N_HALF =
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    IERC20Like public immutable usdc;
    IERC20Like public immutable aToken;
    IAavePoolLike public immutable aavePool;

    address public developerWallet;
    uint256 public minVerifierStake;
    uint16 public groupVerifierFeeBps;

    uint256 public nextWilliamId;
    uint256 public totalWilliamShares;

    mapping(uint256 => William) public williams;
    mapping(uint256 => address[]) private _participantsByWilliam;

    mapping(uint256 => string) private _irlPromptByWilliam;
    mapping(uint256 => string[]) private _irlEvidenceCidsByWilliam;
    mapping(uint256 => AlarmData) public alarmDataByWilliam;
    mapping(uint256 => AppTimerData) public appTimerDataByWilliam;

    mapping(uint256 => uint256) public resolutionNonceByWilliam;

    mapping(address => address) public defaultLocalAgentBySca;
    mapping(address => uint256) public verifierStakeByAddress;
    mapping(address => bool) public verifierPermissionByAddress;

    /// @param usdc_ Token base del stake (USDC en Avalanche C-Chain).
    /// @param aavePool_ Pool compatible con interfaz Aave V3 (supply/withdraw).
    /// @param aToken_ aToken correspondiente al activo depositado.
    /// @param developerWallet_ Wallet que recibe tip en caso de fallo.
    /// @dev Se aprueba USDC infinito al pool una sola vez para reducir approve repetidos.
    constructor(address usdc_, address aavePool_, address aToken_, address developerWallet_)
        OwnableLite(msg.sender)
    {
        if (usdc_ == address(0) || aavePool_ == address(0) || aToken_ == address(0) || developerWallet_ == address(0)) {
            revert ZeroAddress();
        }
        usdc = IERC20Like(usdc_);
        aToken = IERC20Like(aToken_);
        aavePool = IAavePoolLike(aavePool_);
        developerWallet = developerWallet_;
        groupVerifierFeeBps = 500;
        nextWilliamId = 1;

        bool approved = usdc.approve(aavePool_, type(uint256).max);
        if (!approved) revert TransferFailed();
    }

    /// @notice Crea un WilliAm, recibe stake en USDC y lo deposita inmediatamente en Aave.
    /// @dev
    ///  - Valida regla obligatoria de mínimo 30 días entre inicio y fin.
    ///  - Usa share accounting para repartir yield de forma proporcional y gas-eficiente.
    ///  - Guarda metadata específica de subtipo en mappings auxiliares.
    ///  - Emite eventos indexables para nodos P2P/DePIN.
    /// @param base Parámetros base comunes a cualquier subtipo.
    /// @param subtypeData Payload ABI-encoded según `base.kind`:
    ///        IRL -> (string prompt, string[] cids)
    ///        Alarma -> (uint32 targetSecondOfDay, uint8 activeDaysMask, uint32 maxReactionSeconds)
    ///        AppTimer -> (bytes32 appId, uint32 maxMinutesPerWeek)
    function createWilliam(CreateBaseParams calldata base, bytes calldata subtypeData)
        external
        nonReentrant
        returns (uint256 williamId)
    {
        if (base.stakeAmount == 0) revert InvalidAmount();
        if (base.endAt < base.startAt + 30 days) revert InvalidDates();
        if (base.devTipPct > 100) revert InvalidTipPct();

        bool isGroup = base.isGroup;
        if (isGroup) {
            if (base.participants.length < 2) revert InvalidParticipants();
        } else {
            if (base.participants.length > 1) revert InvalidParticipants();
        }

        uint256 assetsBefore = totalManagedAssets();
        uint256 newShares = _previewSharesForDeposit(base.stakeAmount, assetsBefore);
        if (newShares == 0 || newShares > type(uint128).max) revert InvalidAmount();

        bool pulled = usdc.transferFrom(msg.sender, address(this), base.stakeAmount);
        if (!pulled) revert TransferFailed();
        _depositIntoAave(base.stakeAmount);

        williamId = nextWilliamId;
        unchecked {
            nextWilliamId = williamId + 1;
        }

        address payoutRecipient = base.payoutRecipient == address(0) ? msg.sender : base.payoutRecipient;

        address localAgent;
        if (!isGroup) {
            localAgent = base.localAgent;
            if (localAgent == address(0)) {
                localAgent = defaultLocalAgentBySca[msg.sender];
            }
            if (localAgent == address(0)) revert InvalidSigner();
        }

        William storage william = williams[williamId];
        william.creator = msg.sender;
        william.payoutRecipient = payoutRecipient;
        william.localAgent = localAgent;
        william.principal = base.stakeAmount;
        william.shares = uint128(newShares);
        william.startAt = base.startAt;
        william.endAt = base.endAt;
        william.extraLockDays = base.extraLockDays;
        william.devTipPct = base.devTipPct;
        william.kind = uint8(base.kind);
        william.state = uint8(WilliamState.Active);
        william.isGroup = isGroup;

        totalWilliamShares += newShares;

        _storeParticipants(williamId, msg.sender, base.participants, isGroup);
        _storeSubtypeData(williamId, base.kind, subtypeData);

        _emitWilliamCreated(williamId, william);
    }

    /// @notice Resuelve un WilliAm individual validando firma del Agente Local autorizado.
    /// @dev Usa `ecrecover` con anti-replay por nonce + chainId + verifyingContract.
    /// @param williamId ID del reto.
    /// @param successVerdict true si el veredicto firmado es éxito.
    /// @param signature Firma ECDSA del agente local.
    function resolvePersonalWilliam(uint256 williamId, bool successVerdict, bytes calldata signature)
        external
        nonReentrant
    {
        William storage william = williams[williamId];
        if (william.creator == address(0)) revert InvalidAmount();
        if (william.isGroup) revert NotPersonal();
        if (WilliamState(william.state) != WilliamState.Active) revert InvalidState();
        if (block.timestamp < william.endAt) revert VerificationTooEarly();

        bytes32 digest = _resolutionDigest(
            williamId,
            successVerdict,
            william.payoutRecipient,
            resolutionNonceByWilliam[williamId]
        );
        address signer = _recoverSigner(digest, signature);
        if (signer != william.localAgent) revert InvalidSigner();

        unchecked {
            resolutionNonceByWilliam[williamId] += 1;
        }

        if (successVerdict) {
            _finalizeSuccess(williamId, signer, william.payoutRecipient);
        } else {
            _finalizeFailure(williamId, signer);
        }
    }

    /// @notice Resuelve un WilliAm grupal validando firma de Nodo Verificador.
    /// @dev El verificador debe tener permiso explícito o stake mínimo configurado.
    /// @param williamId ID del reto.
    /// @param successVerdict true si el veredicto firmado es éxito.
    /// @param winner Ganador grupal (si es success; debe pertenecer a participantes).
    /// @param verifierSignature Firma del nodo verificador.
    function resolveGroupWilliam(uint256 williamId, bool successVerdict, address winner, bytes calldata verifierSignature)
        external
        nonReentrant
    {
        William storage william = williams[williamId];
        if (william.creator == address(0)) revert InvalidAmount();
        if (!william.isGroup) revert NotGroup();
        if (WilliamState(william.state) != WilliamState.Active) revert InvalidState();
        if (block.timestamp < william.endAt) revert VerificationTooEarly();

        address winnerRecipient = successVerdict
            ? (winner == address(0) ? william.payoutRecipient : winner)
            : william.payoutRecipient;

        if (successVerdict) {
            if (!_isParticipant(williamId, winnerRecipient)) revert InvalidWinner();
        }

        bytes32 digest = _resolutionDigest(
            williamId,
            successVerdict,
            winnerRecipient,
            resolutionNonceByWilliam[williamId]
        );
        address signer = _recoverSigner(digest, verifierSignature);
        if (!_isVerifierAllowed(signer)) revert VerifierNotAllowed();

        unchecked {
            resolutionNonceByWilliam[williamId] += 1;
        }

        william.verifier = signer;

        if (successVerdict) {
            _finalizeSuccess(williamId, signer, winnerRecipient);
        } else {
            _finalizeFailure(williamId, signer);
        }
    }

    /// @notice Reclama fondos retenidos por soft-fail una vez vencido el lock extra.
    /// @dev Mantener shares durante el lock permite que siga acumulando yield hasta el claim.
    function claimSoftFailFunds(uint256 williamId) external nonReentrant {
        William storage william = williams[williamId];
        if (william.creator == address(0)) revert InvalidAmount();
        if (WilliamState(william.state) != WilliamState.Fallido) revert InvalidState();
        if (william.shares == 0) revert AlreadyClaimed();
        if (block.timestamp < william.unlockAt) revert FundsStillLocked();

        uint256 payout = _positionValueFromShares(william.shares);
        uint256 sharesToBurn = william.shares;

        _burnWilliamShares(sharesToBurn);
        william.shares = 0;
        william.unlockAt = 0;

        _pullLiquidityIfNeeded(payout);
        bool sent = usdc.transfer(william.payoutRecipient, payout);
        if (!sent) revert TransferFailed();

        emit SoftFailClaimed(williamId, william.payoutRecipient, payout);
    }

    function setDefaultLocalAgent(address localAgent) external {
        if (localAgent == address(0)) revert ZeroAddress();
        defaultLocalAgentBySca[msg.sender] = localAgent;
        emit DefaultLocalAgentUpdated(msg.sender, localAgent);
    }

    function stakeAsVerifier(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        bool pulled = usdc.transferFrom(msg.sender, address(this), amount);
        if (!pulled) revert TransferFailed();

        verifierStakeByAddress[msg.sender] += amount;
        emit VerifierStaked(msg.sender, amount);
    }

    function unstakeVerifier(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        uint256 current = verifierStakeByAddress[msg.sender];
        if (amount > current) revert InvalidAmount();

        verifierStakeByAddress[msg.sender] = current - amount;
        bool sent = usdc.transfer(msg.sender, amount);
        if (!sent) revert TransferFailed();

        emit VerifierUnstaked(msg.sender, amount);
    }

    function setVerifierPermission(address verifier, bool allowed) external onlyOwner {
        verifierPermissionByAddress[verifier] = allowed;
        emit VerifierPermissionUpdated(verifier, allowed);
    }

    function setMinVerifierStake(uint256 newMinVerifierStake) external onlyOwner {
        uint256 previous = minVerifierStake;
        minVerifierStake = newMinVerifierStake;
        emit MinVerifierStakeUpdated(previous, newMinVerifierStake);
    }

    function setGroupVerifierFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > 10_000) revert InvalidAmount();
        uint16 previous = groupVerifierFeeBps;
        groupVerifierFeeBps = newFeeBps;
        emit GroupVerifierFeeBpsUpdated(previous, newFeeBps);
    }

    function setDeveloperWallet(address newDeveloperWallet) external onlyOwner {
        if (newDeveloperWallet == address(0)) revert ZeroAddress();
        address previous = developerWallet;
        developerWallet = newDeveloperWallet;
        emit DeveloperWalletUpdated(previous, newDeveloperWallet);
    }

    function participantsOf(uint256 williamId) external view returns (address[] memory) {
        return _participantsByWilliam[williamId];
    }

    function irlPromptOf(uint256 williamId) external view returns (string memory) {
        return _irlPromptByWilliam[williamId];
    }

    function irlEvidenceCidsOf(uint256 williamId) external view returns (string[] memory) {
        return _irlEvidenceCidsByWilliam[williamId];
    }

    function totalManagedAssets() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + aToken.balanceOf(address(this));
    }

    function previewWilliamValue(uint256 williamId) external view returns (uint256) {
        William storage william = williams[williamId];
        if (william.creator == address(0) || william.shares == 0) return 0;
        return _positionValueFromShares(william.shares);
    }

    function _storeParticipants(uint256 williamId, address creator, address[] calldata participants, bool isGroup) internal {
        address[] storage target = _participantsByWilliam[williamId];

        if (participants.length == 0) {
            target.push(creator);
            emit WilliamParticipants(williamId, target);
            return;
        }

        for (uint256 i = 0; i < participants.length; i++) {
            address participant = participants[i];
            if (participant == address(0)) revert InvalidParticipants();
            target.push(participant);
        }

        if (!isGroup && target.length != 1) revert InvalidParticipants();
        if (isGroup && target.length < 2) revert InvalidParticipants();

        emit WilliamParticipants(williamId, target);
    }

    function _storeSubtypeData(uint256 williamId, WilliamKind kind, bytes calldata subtypeData) internal {
        if (kind == WilliamKind.IRL) {
            (string memory prompt, string[] memory evidenceCids) = abi.decode(subtypeData, (string, string[]));
            if (bytes(prompt).length == 0) revert InvalidSubtypeData();

            _irlPromptByWilliam[williamId] = prompt;
            string[] storage target = _irlEvidenceCidsByWilliam[williamId];
            for (uint256 i = 0; i < evidenceCids.length; i++) {
                target.push(evidenceCids[i]);
            }

            emit WilliamIRLMetadata(williamId, prompt, evidenceCids);
            return;
        }

        if (kind == WilliamKind.Alarma) {
            (uint32 targetSecondOfDay, uint8 activeDaysMask, uint32 maxReactionSeconds) =
                abi.decode(subtypeData, (uint32, uint8, uint32));
            if (targetSecondOfDay >= 86_400 || activeDaysMask == 0 || maxReactionSeconds == 0) {
                revert InvalidSubtypeData();
            }

            alarmDataByWilliam[williamId] = AlarmData({
                targetSecondOfDay: targetSecondOfDay,
                activeDaysMask: activeDaysMask,
                maxReactionSeconds: maxReactionSeconds
            });
            emit WilliamAlarmMetadata(williamId, targetSecondOfDay, activeDaysMask, maxReactionSeconds);
            return;
        }

        if (kind == WilliamKind.AppTimer) {
            (bytes32 appId, uint32 maxMinutesPerWeek) = abi.decode(subtypeData, (bytes32, uint32));
            if (appId == bytes32(0) || maxMinutesPerWeek == 0) revert InvalidSubtypeData();

            appTimerDataByWilliam[williamId] = AppTimerData({appId: appId, maxMinutesPerWeek: maxMinutesPerWeek});
            emit WilliamAppTimerMetadata(williamId, appId, maxMinutesPerWeek);
            return;
        }

        revert InvalidSubtypeData();
    }

    function _emitWilliamCreated(uint256 williamId, William storage william) internal {
        emit WilliamCreated(
            williamId,
            william.creator,
            william.isGroup,
            william.kind,
            william.principal,
            william.startAt,
            william.endAt,
            william.extraLockDays,
            william.devTipPct,
            william.payoutRecipient,
            william.localAgent
        );
    }

    function _finalizeSuccess(uint256 williamId, address signer, address payoutRecipient) internal {
        if (payoutRecipient == address(0)) revert InvalidRecipient();

        William storage william = williams[williamId];
        uint256 grossPosition = _positionValueFromShares(william.shares);

        uint256 verifierReward;
        if (william.isGroup && signer != address(0)) {
            uint256 generatedYield = grossPosition > william.principal ? grossPosition - william.principal : 0;
            verifierReward = (generatedYield * groupVerifierFeeBps) / 10_000;
            if (verifierReward > grossPosition) verifierReward = grossPosition;
        }

        uint256 payoutToUser = grossPosition - verifierReward;

        _burnWilliamShares(william.shares);
        william.shares = 0;
        william.state = uint8(WilliamState.Exito);

        _pullLiquidityIfNeeded(grossPosition);

        if (verifierReward > 0) {
            bool sentVerifier = usdc.transfer(signer, verifierReward);
            if (!sentVerifier) revert TransferFailed();
        }

        bool sentUser = usdc.transfer(payoutRecipient, payoutToUser);
        if (!sentUser) revert TransferFailed();

        emit WilliamResolved(
            williamId,
            uint8(WilliamState.Exito),
            true,
            signer,
            grossPosition,
            0,
            verifierReward,
            payoutToUser,
            0
        );
    }

    /// @dev En fallo:
    ///  - paga tip al developer (sobre principal, según requerimiento),
    ///  - paga incentivo al verificador grupal (desde yield),
    ///  - mantiene principal remanente en shares hasta `unlockAt`.
    function _finalizeFailure(uint256 williamId, address signer) internal {
        William storage william = williams[williamId];
        uint256 grossPosition = _positionValueFromShares(william.shares);

        uint256 tipToDeveloper = (uint256(william.principal) * uint256(william.devTipPct)) / 100;
        if (tipToDeveloper > grossPosition) tipToDeveloper = grossPosition;

        uint256 verifierReward;
        if (william.isGroup && signer != address(0)) {
            uint256 generatedYield = grossPosition > william.principal ? grossPosition - william.principal : 0;
            verifierReward = (generatedYield * groupVerifierFeeBps) / 10_000;
            uint256 availableAfterTip = grossPosition - tipToDeveloper;
            if (verifierReward > availableAfterTip) verifierReward = availableAfterTip;
        }

        uint256 toSendNow = tipToDeveloper + verifierReward;
        if (toSendNow > 0) {
            _pullLiquidityIfNeeded(toSendNow);

            if (tipToDeveloper > 0) {
                bool sentDev = usdc.transfer(developerWallet, tipToDeveloper);
                if (!sentDev) revert TransferFailed();
            }

            if (verifierReward > 0) {
                bool sentVerifier = usdc.transfer(signer, verifierReward);
                if (!sentVerifier) revert TransferFailed();
            }
        }

        william.state = uint8(WilliamState.Fallido);
        william.unlockAt = uint64(block.timestamp + (uint256(william.extraLockDays) * 1 days));

        emit WilliamResolved(
            williamId,
            uint8(WilliamState.Fallido),
            false,
            signer,
            grossPosition,
            tipToDeveloper,
            verifierReward,
            0,
            william.unlockAt
        );
    }

    /// @dev Hash de resolución con dominio fuerte para evitar replay cross-chain/cross-contract.
    function _resolutionDigest(uint256 williamId, bool successVerdict, address payoutRecipient, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                RESOLUTION_TYPEHASH,
                williamId,
                successVerdict,
                payoutRecipient,
                nonce,
                block.chainid,
                address(this)
            )
        );
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
    }

    /// @dev Recupera firmante ECDSA y aplica chequeos anti-malleability (s en half-order + v válido).
    function _recoverSigner(bytes32 digest, bytes calldata signature) internal pure returns (address signer) {
        if (signature.length != 65) revert InvalidSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert InvalidSignatureV();
        if (uint256(s) > uint256(SECP256K1N_HALF)) revert InvalidSignatureS();

        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSigner();
    }

    function _isParticipant(uint256 williamId, address candidate) internal view returns (bool) {
        address[] storage group = _participantsByWilliam[williamId];
        for (uint256 i = 0; i < group.length; i++) {
            if (group[i] == candidate) return true;
        }
        return false;
    }

    function _isVerifierAllowed(address signer) internal view returns (bool) {
        return verifierPermissionByAddress[signer] || verifierStakeByAddress[signer] >= minVerifierStake;
    }

    function _depositIntoAave(uint256 amount) internal {
        aavePool.supply(address(usdc), amount, address(this), 0);
    }

    function _pullLiquidityIfNeeded(uint256 amountNeeded) internal {
        uint256 liquid = usdc.balanceOf(address(this));
        if (liquid >= amountNeeded) return;

        uint256 missing = amountNeeded - liquid;
        aavePool.withdraw(address(usdc), missing, address(this));
    }

    function _previewSharesForDeposit(uint256 amount, uint256 assetsBefore) internal view returns (uint256) {
        if (totalWilliamShares == 0 || assetsBefore == 0) return amount;
        return (amount * totalWilliamShares) / assetsBefore;
    }

    /// @dev Convierte shares en valor actual usando activos gestionados totales.
    ///      Diseño similar a vault accounting para repartir rendimiento proporcionalmente.
    function _positionValueFromShares(uint256 shares) internal view returns (uint256) {
        uint256 currentTotalShares = totalWilliamShares;
        if (shares == 0 || currentTotalShares == 0) return 0;
        return (shares * totalManagedAssets()) / currentTotalShares;
    }

    function _burnWilliamShares(uint256 shares) internal {
        totalWilliamShares -= shares;
    }
}
