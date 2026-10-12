# WillFolks · contratos

Contratos de WillFolks sobre Avalanche. El contrato vigente es **`WillFolksEscrow`** (fase 1):
el usuario bloquea USDC contra una meta y un atestador autorizado firma el veredicto.

> **Estado:** sin auditar y solo probado en local. No desplegar en mainnet.
> El repo vive en el servidor git local (`http://localhost:3300/WillFolks-App/willfolks-smartcontracts`).

## Qué hace `WillFolksEscrow`

| Paso | Función | Quién la llama | Efecto |
| --- | --- | --- | --- |
| Crear meta | `createGoal` | El usuario | Bloquea el stake en el contrato |
| Veredicto | `resolve` | Cualquiera, con la firma del atestador | Éxito: el stake vuelve. Fallo: queda bloqueado `lockDays` tras el fin de la meta |
| Tras el bloqueo | `claim` | Cualquiera | El stake vuelve al creador |
| Atestador caído | `reclaim` | Cualquiera, pasado el plazo de gracia | El stake vuelve al creador |
| Arrepentimiento | `cancel` | El creador, antes de `startAt` | El stake vuelve al creador |

Propiedades que el contrato garantiza y que las pruebas verifican:

- **El stake solo puede salir hacia su creador.** No existe ninguna función que lo envíe a otra dirección.
- **El creador no puede firmarse el éxito.** Solo valen las firmas de direcciones en la lista de atestadores.
- **Ningún stake queda atrapado.** Si nadie resuelve hasta `endAt + resolutionGrace`, el creador lo recupera.
- **El owner no toca fondos.** Solo administra atestadores, el tope por meta y la pausa de creación.
- **La pausa no retiene a nadie.** Detiene metas nuevas; resolver, reclamar y cancelar siguen activos.
- **Fallar nunca libera antes que cumplir.** El bloqueo cuenta desde `endAt`, o desde el veredicto si llega después.

### Veredicto firmado (EIP-712)

```
Dominio:   name "WillFolksEscrow", version "1", chainId, verifyingContract
Resolution(uint256 goalId, bool success, bytes32 evidenceHash, uint40 validUntil)
```

- El **fallo** puede atestarse desde `startAt` (intentos agotados); el **éxito** solo desde `endAt`.
- La firma no sirve para otra meta, otro veredicto, otro contrato ni otra cadena.
- El atestador puede ser una cuenta de contrato (ERC-1271).
- `evidenceHash` ancla el registro de evidencia que vive fuera de la cadena.

### Límites deliberados de la fase 1

- Un solo atestador de confianza (el backend). El quórum, el slashing y la apelación on-chain son fases posteriores.
- Sin metas grupales, sin donación al desarrollador y sin rendimiento (Aave).
- Sin proxy: el contrato no es upgradeable. Un cambio de lógica es un despliegue nuevo.
- La verificación de la meta (alarma, uso de apps, ubicación, evidencia) ocurre fuera de la cadena;
  el contrato solo guarda `metadataHash`.
- Reglas diarias (check-ins, intentos) las lleva el backend, que firma un único veredicto por meta.
- Si el emisor del token bloquea la dirección del creador (lista negra de USDC), su stake no puede
  devolverse: el contrato no tiene, a propósito, otra dirección de salida.

## Uso

Requiere [Foundry](https://book.getfoundry.sh/) y `jq` para la prueba e2e.

```bash
git submodule update --init --recursive
forge build
forge test                      # unitarias, fuzzing e invariantes
./e2e/local.sh                  # e2e contra Anvil por RPC
FOUNDRY_PROFILE=ci forge test   # más iteraciones de fuzzing e invariantes
```

### Pruebas

| Archivo | Qué cubre |
| --- | --- |
| `test/WillFolksEscrow.t.sol` | Unitarias y fuzzing: creación, veredictos, firmas, plazos, pausa, administración |
| `test/WillFolksEscrow.invariant.t.sol` | Invariantes con secuencias aleatorias: el saldo coincide con lo custodiado y cada actor conserva lo suyo |
| `e2e/local.sh` | Cinco flujos completos contra un nodo real, con veredictos firmados fuera del contrato |

La prueba e2e levanta su propio Anvil (puerto `8555`, configurable con `E2E_PORT`), despliega un
USDC de prueba y el escrow, y recorre: meta cumplida, meta fallida con bloqueo, intentos de trampa,
atestador caído y cancelación con pausa.

### Despliegue

Local:

```bash
anvil
PRIVATE_KEY=<llave de anvil> ESCROW_ATTESTOR=<dirección> \
  forge script script/DeployEscrowLocal.s.sol:DeployEscrowLocalScript \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

Fuji (pendiente; ver `.env.example`):

```bash
forge script script/DeployEscrow.s.sol:DeployEscrowScript --rpc-url "$RPC_URL" --broadcast
```

El script deja como owner a quien despliega y, si `ESCROW_OWNER` es otra dirección, inicia el
traspaso en dos pasos: el nuevo owner debe llamar a `acceptOwnership()`.

## `WillFolksSingleton` (diseño original)

`src/WillFolksSingleton.sol` es el primer diseño: stake con rendimiento en Aave, metas grupales y
propina al desarrollador. Se conserva como referencia y **no debe desplegarse**: el creador elige
quién firma su resultado, los grupos no tienen pozo real y la propina puede llegar al 100% del stake.
`WillFolksEscrow` corrige el primer punto y deja los otros dos fuera del alcance.
