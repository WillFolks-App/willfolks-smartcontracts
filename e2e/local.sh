#!/usr/bin/env bash
# Prueba e2e local de WillFolksEscrow contra un nodo real (Anvil), por RPC.
#
# A diferencia de `forge test`, aquí cada paso es una transacción firmada por una
# llave distinta y el veredicto se firma fuera del contrato con datos tipados
# EIP-712, igual que lo hará el backend atestador.
#
#   ./e2e/local.sh            # levanta Anvil, despliega y recorre los 5 flujos
#   E2E_PORT=8555 ./e2e/local.sh
set -euo pipefail
# Sin esto, un fallo dentro de $(...) no detiene el script y la prueba seguiría con datos viejos.
shopt -s inherit_errexit

cd "$(dirname "$0")/.."

PORT="${E2E_PORT:-8555}"
RPC="http://127.0.0.1:${PORT}"
CHAIN_ID=31337

# Cuentas deterministas de Anvil, derivadas de su mnemónico de prueba público.
# Nunca usarlas fuera de local.
MNEMONIC="test test test test test test test test test test test junk"
anvil_key() { cast wallet private-key "$MNEMONIC" "$1"; }
DEPLOYER_PK=$(anvil_key 0)
ATTESTOR_PK=$(anvil_key 1)
USER_PK=$(anvil_key 2)
RELAYER_PK=$(anvil_key 3)
INTRUDER_PK=$(anvil_key 4)

ATTESTOR=$(cast wallet address --private-key "$ATTESTOR_PK")
USER=$(cast wallet address --private-key "$USER_PK")
RELAYER=$(cast wallet address --private-key "$RELAYER_PK")
INTRUDER=$(cast wallet address --private-key "$INTRUDER_PK")

STAKE=25000000            # 25 USDC (6 decimales)
FUNDING=100000000         # 100 USDC
EVIDENCE=$(cast keccak "e2e evidence")
METADATA=$(cast keccak "alarm 07:00 mon-fri")
GRACE=86400               # igual que DeployEscrowLocal

passed=0
log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok() { passed=$((passed + 1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

ANVIL_LOG=$(mktemp)
anvil --port "$PORT" --chain-id "$CHAIN_ID" --silent >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true; rm -f "$ANVIL_LOG"' EXIT
for _ in $(seq 1 50); do
  cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 0.1
done
cast block-number --rpc-url "$RPC" >/dev/null || fail "Anvil no arrancó en el puerto $PORT"

# ------------------------------------------------------------------ helpers
now() { cast block latest --field timestamp --rpc-url "$RPC"; }
warp() {
  cast rpc evm_increaseTime "$1" --rpc-url "$RPC" >/dev/null
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null
}
call() { cast call "$@" --rpc-url "$RPC"; }
send() { cast send "$@" --rpc-url "$RPC" >/dev/null; }
balance() { call "$USDC" "balanceOf(address)(uint256)" "$1" | awk '{print $1}'; }
state() { call "$ESCROW" "getGoal(uint256)((address,uint40,uint40,uint16,uint128,uint40,uint8,uint8,bytes32))" "$1" | tr -d '()' | awk -F', ' '{print $8}'; }
last_goal() { echo $(($(call "$ESCROW" "nextGoalId()(uint256)") - 1)); }

expect_eq() { [ "$1" = "$2" ] && ok "$3" || fail "$3: esperado $2, obtenido $1"; }

# expect_revert <NombreDelError> <args de cast send...>
expect_revert() {
  local name="$1"; shift
  local selector output
  selector=$(cast sig "${name}()")
  if output=$(cast send "$@" --rpc-url "$RPC" 2>&1); then
    fail "debía revertir con $name y no revirtió"
  fi
  if grep -q -e "$name" -e "$selector" <<<"$output"; then
    ok "revierte con $name"
  else
    fail "debía revertir con $name: $output"
  fi
}

# create_goal <pk> <segundos hasta el inicio> <duración> <días de bloqueo>
create_goal() {
  local start=$(($(now) + $2))
  send "$ESCROW" "createGoal(uint128,uint40,uint40,uint16,uint8,bytes32)" \
    "$STAKE" "$start" "$((start + $3))" "$4" 0 "$METADATA" --private-key "$1"
  last_goal
}

# sign_verdict <pk> <goalId> <true|false> <validUntil>  -> firma EIP-712
sign_verdict() {
  cast wallet sign --private-key "$1" --data "$(jq -cn \
    --arg contract "$ESCROW" --arg evidence "$EVIDENCE" \
    --argjson chain "$CHAIN_ID" --argjson goal "$2" --argjson success "$3" --argjson until "$4" '{
      types: {
        EIP712Domain: [
          {name: "name", type: "string"}, {name: "version", type: "string"},
          {name: "chainId", type: "uint256"}, {name: "verifyingContract", type: "address"}
        ],
        Resolution: [
          {name: "goalId", type: "uint256"}, {name: "success", type: "bool"},
          {name: "evidenceHash", type: "bytes32"}, {name: "validUntil", type: "uint40"}
        ]
      },
      primaryType: "Resolution",
      domain: {name: "WillFolksEscrow", version: "1", chainId: $chain, verifyingContract: $contract},
      message: {goalId: $goal, success: $success, evidenceHash: $evidence, validUntil: $until}
    }')"
}

# resolve_args <goalId> <true|false> <validUntil> <attestor> <signature>
RESOLVE_SIG="resolve(uint256,bool,bytes32,uint40,address,bytes)"

# ---------------------------------------------------------------- despliegue
log "Despliegue"
PRIVATE_KEY="$DEPLOYER_PK" ESCROW_ATTESTOR="$ATTESTOR" forge script \
  script/DeployEscrowLocal.s.sol:DeployEscrowLocalScript --rpc-url "$RPC" --broadcast >/dev/null
RUN="broadcast/DeployEscrowLocal.s.sol/${CHAIN_ID}/run-latest.json"
USDC=$(cast to-check-sum-address "$(jq -r '[.transactions[] | select(.contractName == "MockERC20")][0].contractAddress' "$RUN")")
ESCROW=$(cast to-check-sum-address "$(jq -r '[.transactions[] | select(.contractName == "WillFolksEscrow")][0].contractAddress' "$RUN")")
echo "  USDC   $USDC"
echo "  Escrow $ESCROW"

expect_eq "$(call "$ESCROW" "isAttestor(address)(bool)" "$ATTESTOR")" "true" "el atestador quedó autorizado"
expect_eq "$(call "$ESCROW" "token()(address)")" "$USDC" "el escrow usa el USDC desplegado"

send "$USDC" "mint(address,uint256)" "$USER" "$FUNDING" --private-key "$DEPLOYER_PK"
send "$USDC" "mint(address,uint256)" "$INTRUDER" "$FUNDING" --private-key "$DEPLOYER_PK"
MAX_UINT=$(cast max-uint)
send "$USDC" "approve(address,uint256)" "$ESCROW" "$MAX_UINT" --private-key "$USER_PK"
send "$USDC" "approve(address,uint256)" "$ESCROW" "$MAX_UINT" --private-key "$INTRUDER_PK"

# ------------------------------------------------------------ 1 · meta cumplida
log "1 · Meta cumplida: el atestador firma el éxito y el stake vuelve"
GOAL=$(create_goal "$USER_PK" 0 3600 2)
expect_eq "$(balance "$USER")" "$((FUNDING - STAKE))" "el stake salió de la cuenta del usuario"
expect_eq "$(balance "$ESCROW")" "$STAKE" "el escrow custodia el stake"

UNTIL=$(($(now) + 7200))
SIG=$(sign_verdict "$ATTESTOR_PK" "$GOAL" true "$UNTIL")
expect_revert TooEarlyForSuccess "$ESCROW" "$RESOLVE_SIG" "$GOAL" true "$EVIDENCE" "$UNTIL" "$ATTESTOR" "$SIG" --private-key "$RELAYER_PK"

warp 3600
send "$ESCROW" "$RESOLVE_SIG" "$GOAL" true "$EVIDENCE" "$UNTIL" "$ATTESTOR" "$SIG" --private-key "$RELAYER_PK"
expect_eq "$(state "$GOAL")" "2" "la meta quedó en Succeeded"
expect_eq "$(balance "$USER")" "$FUNDING" "el usuario recuperó su stake"
expect_eq "$(balance "$RELAYER")" "0" "el relayer que envió la transacción no recibió nada"

# ------------------------------------------------- 2 · meta fallida y bloqueo
log "2 · Meta fallida: el stake queda bloqueado 2 días y luego vuelve"
GOAL=$(create_goal "$USER_PK" 0 3600 2)
warp 600
UNTIL=$(($(now) + 3600))
SIG=$(sign_verdict "$ATTESTOR_PK" "$GOAL" false "$UNTIL")
send "$ESCROW" "$RESOLVE_SIG" "$GOAL" false "$EVIDENCE" "$UNTIL" "$ATTESTOR" "$SIG" --private-key "$RELAYER_PK"
expect_eq "$(state "$GOAL")" "3" "la meta quedó en Failed"
expect_eq "$(balance "$USER")" "$((FUNDING - STAKE))" "el stake sigue bloqueado"
expect_revert StillLocked "$ESCROW" "claim(uint256)" "$GOAL" --private-key "$USER_PK"

warp $((2 * 86400))
send "$ESCROW" "claim(uint256)" "$GOAL" --private-key "$RELAYER_PK"
expect_eq "$(state "$GOAL")" "4" "la meta quedó en Claimed"
expect_eq "$(balance "$USER")" "$FUNDING" "el usuario recuperó su stake tras el bloqueo"

# ------------------------------------------------ 3 · intentos de hacer trampa
log "3 · Trampas: nadie fuera de la lista de atestadores puede resolver"
GOAL=$(create_goal "$INTRUDER_PK" 0 3600 2)
warp 3600
UNTIL=$(($(now) + 3600))
SELF_SIG=$(sign_verdict "$INTRUDER_PK" "$GOAL" true "$UNTIL")
expect_revert AttestorNotAuthorized "$ESCROW" "$RESOLVE_SIG" "$GOAL" true "$EVIDENCE" "$UNTIL" "$INTRUDER" "$SELF_SIG" --private-key "$INTRUDER_PK"
expect_revert InvalidSignature "$ESCROW" "$RESOLVE_SIG" "$GOAL" true "$EVIDENCE" "$UNTIL" "$ATTESTOR" "$SELF_SIG" --private-key "$INTRUDER_PK"

FAIL_SIG=$(sign_verdict "$ATTESTOR_PK" "$GOAL" false "$UNTIL")
expect_revert InvalidSignature "$ESCROW" "$RESOLVE_SIG" "$GOAL" true "$EVIDENCE" "$UNTIL" "$ATTESTOR" "$FAIL_SIG" --private-key "$INTRUDER_PK"
send "$ESCROW" "$RESOLVE_SIG" "$GOAL" false "$EVIDENCE" "$UNTIL" "$ATTESTOR" "$FAIL_SIG" --private-key "$RELAYER_PK"
expect_eq "$(state "$GOAL")" "3" "el veredicto real (fallo) sí se aplica"
expect_revert GoalNotActive "$ESCROW" "$RESOLVE_SIG" "$GOAL" false "$EVIDENCE" "$UNTIL" "$ATTESTOR" "$FAIL_SIG" --private-key "$RELAYER_PK"
warp $((2 * 86400))
send "$ESCROW" "claim(uint256)" "$GOAL" --private-key "$INTRUDER_PK"
expect_eq "$(balance "$INTRUDER")" "$FUNDING" "tras el bloqueo recupera solo lo suyo"

# ------------------------------------------- 4 · el atestador nunca responde
log "4 · Atestador caído: el stake no queda atrapado"
GOAL=$(create_goal "$USER_PK" 0 3600 90)
warp $((3600 + GRACE))
expect_revert ResolutionWindowOpen "$ESCROW" "reclaim(uint256)" "$GOAL" --private-key "$USER_PK"
warp 1
UNTIL=$(($(now) + 3600))
SIG=$(sign_verdict "$ATTESTOR_PK" "$GOAL" false "$UNTIL")
expect_revert ResolutionWindowClosed "$ESCROW" "$RESOLVE_SIG" "$GOAL" false "$EVIDENCE" "$UNTIL" "$ATTESTOR" "$SIG" --private-key "$RELAYER_PK"
send "$ESCROW" "reclaim(uint256)" "$GOAL" --private-key "$RELAYER_PK"
expect_eq "$(state "$GOAL")" "5" "la meta quedó en Expired"
expect_eq "$(balance "$USER")" "$FUNDING" "el usuario recuperó su stake sin atestador"

# ------------------------------------------------- 5 · cancelación y pausa
log "5 · Cancelación antes de empezar y pausa de emergencia"
GOAL=$(create_goal "$USER_PK" 3600 3600 2)
expect_revert NotCreator "$ESCROW" "cancel(uint256)" "$GOAL" --private-key "$INTRUDER_PK"
send "$ESCROW" "cancel(uint256)" "$GOAL" --private-key "$USER_PK"
expect_eq "$(state "$GOAL")" "6" "la meta quedó en Cancelled"

GOAL=$(create_goal "$USER_PK" 0 3600 0)
send "$ESCROW" "pause()" --private-key "$DEPLOYER_PK"
START=$(now)
expect_revert EnforcedPause "$ESCROW" "createGoal(uint128,uint40,uint40,uint16,uint8,bytes32)" \
  "$STAKE" "$START" "$((START + 3600))" 0 0 "$METADATA" --private-key "$USER_PK"
warp 3600
UNTIL=$(($(now) + 3600))
SIG=$(sign_verdict "$ATTESTOR_PK" "$GOAL" true "$UNTIL")
send "$ESCROW" "$RESOLVE_SIG" "$GOAL" true "$EVIDENCE" "$UNTIL" "$ATTESTOR" "$SIG" --private-key "$RELAYER_PK"
expect_eq "$(balance "$USER")" "$FUNDING" "con el contrato en pausa las metas existentes se resuelven"

# ------------------------------------------------------------------- cierre
log "Cierre"
expect_eq "$(balance "$ESCROW")" "0" "el escrow terminó sin fondos"
expect_eq "$(call "$ESCROW" "totalLocked()(uint256)")" "0" "totalLocked terminó en cero"
expect_eq "$(balance "$RELAYER")" "0" "el relayer nunca recibió fondos"

printf '\n\033[1;32m%d comprobaciones e2e pasaron\033[0m\n' "$passed"
