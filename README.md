# Coin

> Proyecto: Coin — AI Receivables Agent (microservicios). Diseño v4.1 y contratos de API; aún sin código.

## Estado

- Carpeta creada: 2026-10-01. Repositorio git propio (`main`, commit inicial).
- `AI_Receivables_Agent_Microservicios_v4.md`: diseño v4.1 (18 unidades en MVP 1, 22 con F2).
- `contracts/`: 21 contratos OpenAPI 3.1 (fichas S1–S18 y los 3 de borde), AsyncAPI de
  `case-service`, componentes comunes (`common/common.yaml`) y reglas de diseño (`.spectral.yaml`).
  Validados el 2026-10-03: Spectral 0 errores, Redocly 0 errores y 0 avisos.
- Sin código todavía. Cuando llegue vivirá en `services/`, `edge/` y `libs/` (v4 §12.2).
- Pendiente: commit del documento y de `contracts/` (sin seguimiento en git todavía).

## Notas

- Los planes técnicos (documentos FTD) viven fuera del repositorio, en `02-DOCS/wiki/ftd/` del harness.
- Validación de los contratos: `scripts/lint-contracts.sh` (todos) o `scripts/lint-contracts.sh <archivo>...`.
  Ejecuta Spectral (reglas de `contracts/.spectral.yaml`), Redocly y `asyncapi validate`; solo los
  errores fallan, los avisos se muestran. Busca los linters en PATH, luego en el Node de Hermes
  (`~/.hermes/tools/node-*/bin`) y por último con `npx -y`.
- El mismo script corre en cuatro gates:
  1. `git commit`: hook `.githooks/pre-commit` sobre los contratos preparados. Activar una vez por clon
     con `git config core.hooksPath .githooks`; saltar con `git commit --no-verify`.
  2. Hermes: hook `pre_verify` (`~/.hermes/agent-hooks/verify-contracts.py`) que lintea todo antes de
     que el agente dé el turno por terminado; el hook `pre_tool_call` (`lint-contracts.py`) ya bloquea
     cada escritura inválida.
  3. GitHub Actions: `.github/workflows/contracts.yml`, en PR y en push a `main` que toquen
     `contracts/`, con las mismas versiones de linters que en local.
  4. Jenkins local (Docker): `Jenkinsfile` + `ci/contracts-lint.Dockerfile`. Una rama con `Jenkinsfile` = un
     pipeline; el hook `.githooks/post-commit` avisa a Jenkins tras cada commit. Se maneja con `jenkinsctl`
     (`01-TOOLS/jenkins/` del harness, fuera de este repositorio): `jenkinsctl result coin`, `jenkinsctl log coin --errors`.
- `.hermes.md` y `.agents/skills/`: contexto y skills de Hermes Agent (herramientas de CI/CD y reglas de contratos).
