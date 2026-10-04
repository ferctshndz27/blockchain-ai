---
name: coin-contracts
description: "Contratos API de Coin: reglas y lint obligatorio"
version: 1.0.0
license: MIT
metadata:
  hermes:
    tags: [openapi, asyncapi, spectral, redocly, contracts, coin, api-design]
    related_skills: [api-design]
---

# Contratos de API de Coin (OpenAPI 3.1 / AsyncAPI 3)

Úsala siempre que vayas a crear o modificar un archivo bajo `contracts/` del proyecto Coin.
Fuente de verdad: `AI_Receivables_Agent_Microservicios_v4.md` §11 (lineamientos) y
`contracts/.spectral.yaml` (las mismas reglas, ejecutables). Contrato de referencia:
`contracts/openapi/case-service.yaml`. Componentes comunes: `contracts/common/common.yaml`.

## Regla cero: nada está terminado sin lint limpio

1. Escribe el archivo con `write_file` o `patch`, nunca con heredocs por terminal. Un hook
   `pre_tool_call` lintea lo que vas a escribir y bloquea la escritura si hay errores; el mensaje
   de bloqueo trae cada error con línea y regla. Corrige el contenido y vuelve a escribir.
2. Antes de dar por cerrado un contrato, ejecuta y pega el resultado en tu respuesta. Usa los binarios
   globales (`asyncapi`, `spectral`, `redocly`): corren sin pedir aprobación. `npx` dispara el prompt de
   aprobación de Hermes y, si nadie responde, pierdes cinco minutos; úsalo solo si `which <binario>` no
   encuentra nada, y entonces con `npx -y`.
   - `spectral lint contracts/openapi/<servicio>.yaml -r contracts/.spectral.yaml`
   - `redocly lint contracts/openapi/<servicio>.yaml`
   - AsyncAPI: `asyncapi validate contracts/asyncapi/<servicio>.yaml`
3. "Hecho" significa 0 errores en ambos linters. Los avisos `operation-description` se resuelven
   escribiendo `description` en cada operación, nunca desactivando la regla.
4. Antes de cerrar el turno, lint global: `scripts/lint-contracts.sh` (sin argumentos lintea los 28
   contratos; ~16 s). Comprueba los `$ref` cruzados y `common/`, que el lint por archivo no ve. Un hook
   `pre_verify` lo ejecuta por ti y, si hay errores, te devuelve la lista en vez de dejarte terminar.

## Reglas que el lint comprueba (las que fallaron en la pasada del 2026-10-02)

- OpenAPI **3.1**: los nulos se escriben `type: [string, 'null']`; `nullable: true` es 3.0 y es error.
- El tenant **nunca** va en ruta, parámetros ni cuerpo: sale del token (`contextToken` o token de
  capacidad). Ninguna propiedad `tenantId`, `organizationId` ni similar.
- POST público con efectos lleva la cabecera `Idempotency-Key` (`$ref` a common). PATCH lleva
  `If-Match` y el recurso expone `etag`; precondición fallida = **412**, nunca 409.
- Rutas `/v1/...` o `/internal/v1/...` (estas con `x-internal: true` y `serviceToken`), en
  kebab-case; propiedades camelCase; errores 4xx/5xx en `application/problem+json`.
- Toda operación, también las internas, declara al menos un 4xx (401/403 vía common).
- No copies el bloque de alias (`Problem`, `Actor`, `IfMatch`, `Cursor`, `Limit`, `serviceToken`)
  si no lo usas: cada componente declarado debe referenciarse. Un alias de `parameters` nunca
  apunta a un `schema`.
- Los enums compartidos entre archivos (canales, estados) coinciden letra por letra: busca el
  valor en los demás contratos antes de escribirlo (`grep -rn MESSENGER contracts/`).
- YAML: todo escalar que contenga `: ` (dos puntos y espacio), `#` o empiece por `*`, `&`, `[`, `{`
  va entre comillas; es la causa más frecuente de bloqueo del hook en AsyncAPI.
- AsyncAPI: incluye **todos** los eventos de la línea `Publica →` de la ficha del servicio en el v4
  y todos los `Consume ←`, aunque la petición solo nombre algunos; si dejas alguno fuera, dilo en la
  línea de cierre como pendiente. Un archivo por servicio, con `asyncapi/case-service.yaml` de plantilla.

## Excepciones de diseño

Si una ruta incumple una regla por diseño documentado (webhooks `/hooks/*`, portal
`/p/{linkToken}`, `/.well-known/jwks.json`), no la "arregles" ni apagues la regla para todos:
añade un `overrides` por archivo o por ruta en `contracts/.spectral.yaml`, con un comentario
que cite la sección del v4 que lo justifica.

## Al terminar un contrato

Una línea de cierre con: archivo, número de rutas y operaciones, resultado del lint (errores y
avisos) y qué quedó pendiente. Sin esa línea el trabajo no está terminado.
