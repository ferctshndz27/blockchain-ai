---
name: jenkins-local
description: "Jenkins y Docker locales: lanzar y leer builds de Coin"
version: 1.0.0
license: MIT
metadata:
  hermes:
    tags: [jenkins, docker, ci, cd, pipeline, jenkinsfile, coin]
    related_skills: [coin-contracts, docker, github-actions, git-workflow]
---

# Jenkins local y Docker (CI/CD de Coin)

Úsala cuando commitees en Coin, cuando toques el `Jenkinsfile` o `ci/`, o cuando el usuario hable de CI, builds,
Jenkins o Docker. Ya está instalado y funcionando: no instales ni configures nada.

## Qué existe

- **Jenkins** en Docker, solo local: http://127.0.0.1:8090. Job `coin` (una rama con `Jenkinsfile` = un pipeline)
  y job `jenkins-smoke` (prueba de humo). Tú eres el usuario `hermes`: puedes leer, lanzar y cancelar builds, no administrar.
- **Docker** del equipo: lo usa Jenkins para los agentes de build (`ci/contracts-lint.Dockerfile` es el del lint).
  Para escribir Dockerfiles usa la skill `docker`.
- El pipeline de Coin ejecuta `scripts/lint-contracts.sh`: el mismo lint que el hook pre-commit, GitHub Actions y tu
  hook `pre_verify`. Una sola fuente de verdad.

## Tu herramienta (ruta absoluta; no está en el PATH)

`/home/fernando/D02/Labs/Qwen-Hermes-Harness/01-TOOLS/jenkins/jenkinsctl <comando>`

| Comando | Para qué |
|---|---|
| `status` | ¿Está Jenkins encendido y autenticado? Cola y ejecutores. |
| `jobs` | Jobs y ramas con su último resultado. |
| `result coin [rama]` | Último build: resultado, etapas, etapa fallida y errores. Sin rama usa la rama actual de Coin. |
| `build coin [rama] --wait` | Lanza un build y espera (120 s). Sale 0 solo si SUCCESS. |
| `log coin [rama] --errors` | Solo las líneas de error con su archivo. Sin `--errors`: las últimas 80 líneas (`--lines N`). |
| `scan coin` | Re-escanea las ramas (para ramas nuevas con `Jenkinsfile`). |
| `log coin --index` | Por qué Jenkins no ve una rama (p. ej. "Jenkinsfile not found"). |
| `up` | Enciende Jenkins si `status` dice que está apagado. |

Códigos de salida: 0 bien; 1 error o build fallido; 2 el build sigue en curso (repite `result`).
Tu terminal corta a 180 s: nunca uses `--timeout` mayor que 150.

## Flujo normal

1. Haz tu commit en la rama de trabajo (el hook pre-commit lintea; nunca `--no-verify`).
2. El hook post-commit avisa a Jenkins y el build arranca solo en unos segundos. No hace falta lanzarlo a mano.
3. `jenkinsctl result coin`. Si dice EN CURSO (sale 2), espera unos segundos y repite.
4. Si FAILURE: `jenkinsctl log coin --errors`, corrige la causa, nuevo commit y vuelve al paso 2.
   No des el trabajo por terminado con un build en rojo.
5. Línea de cierre obligatoria: `Jenkins: <rama> #<n> <resultado>, <etapas>`.

Si `status` dice que Jenkins no responde, ejecuta `jenkinsctl up` (unos 10 s). Solo la primera instalación tarda
minutos. Después de `up`, lanza `jenkinsctl scan coin` para que construya lo que se commiteó mientras estaba apagado.

## Si tocas el Jenkinsfile o ci/

- Pipeline declarativo; cada etapa con su `agent`. Imágenes de Docker con versión fija, nunca `latest`.
- Todo agente en contenedor lleva `args '--cpus=4 -m 4g'` (no le quites recursos al modelo local).
- Sin `--privileged`, sin montar el socket de Docker ni rutas fuera del workspace, sin secretos en claro.
- La lógica va en `scripts/*.sh` (se prueba en local); el `Jenkinsfile` solo la orquesta.
- Los linters del agente (`ci/contracts-lint.Dockerfile`) y los de `.github/workflows/contracts.yml` llevan las
  mismas versiones: si cambias una, cambia la otra.
- Un `Jenkinsfile` nuevo solo se construye cuando está commiteado en una rama: no se prueba sin commit.

## No hagas

- No leas ni muestres el archivo `.env` de `01-TOOLS/jenkins` (contiene contraseñas y el token).
- No ejecutes `down`, `restart` ni `reset` si el usuario no lo pidió. `reset` borra todo el historial de Jenkins.
- No cambies Jenkins por la interfaz web ni edites `01-TOOLS/jenkins/casc/jenkins.yaml`: eso lo decide el usuario.
- No ejecutes `docker run` con `--privileged`. Si `docker` directo da "permission denied" (la sesión aún no tiene el
  grupo), usa `jenkinsctl`, que ya lo gestiona.
