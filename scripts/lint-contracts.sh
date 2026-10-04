#!/usr/bin/env bash
# Lint global de los contratos de Coin (OpenAPI 3.1 + AsyncAPI 3). Única fuente de verdad del gate:
# lo ejecutan el hook pre-commit (.githooks/pre-commit), el hook pre_verify de Hermes
# (~/.hermes/agent-hooks/verify-contracts.py) y el workflow de GitHub Actions (.github/workflows/contracts.yml).
#
# Uso:
#   scripts/lint-contracts.sh                 # todos los contratos
#   scripts/lint-contracts.sh <archivo>...    # solo esos (rutas relativas al repo o absolutas)
#
# Salida: 0 si no hay errores; 1 si algún linter reporta errores; 127 si falta un linter.
# Los avisos (p. ej. operation-description) se muestran pero no fallan: solo severidad "error" bloquea.
# Linters: spectral (reglas de contracts/.spectral.yaml, v4 §11), redocly (estructura OAS) y
# asyncapi validate. Se buscan en PATH, luego en el Node de Hermes (~/.hermes/tools/node-*/bin) y,
# como último recurso, con `npx -y` (lento y en Hermes dispara el prompt de aprobación).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
export CI=true NO_COLOR=1 FORCE_COLOR=0 NPM_CONFIG_UPDATE_NOTIFIER=false

for d in "$HOME"/.hermes/tools/node-*/bin; do
  [ -d "$d" ] && PATH="$PATH:$d"
done
export PATH

tool() { # tool <binario> <paquete npm> → imprime el comando a usar
  if command -v "$1" >/dev/null 2>&1; then echo "$1"; else echo "npx -y $2"; fi
}
SPECTRAL="$(tool spectral @stoplight/spectral-cli)"
REDOCLY="$(tool redocly @redocly/cli)"
ASYNCAPI="$(tool asyncapi @asyncapi/cli)"

openapi=() ; asyncapi=()
if [ "$#" -eq 0 ]; then
  for f in contracts/openapi/*.yaml contracts/openapi/*.yml; do [ -f "$f" ] && openapi+=("$f"); done
  for f in contracts/asyncapi/*.yaml contracts/asyncapi/*.yml; do [ -f "$f" ] && asyncapi+=("$f"); done
else
  for f in "$@"; do
    rel="${f#"$ROOT"/}"
    case "$rel" in
      contracts/openapi/*.y*ml)  [ -f "$rel" ] && openapi+=("$rel") ;;
      contracts/asyncapi/*.y*ml) [ -f "$rel" ] && asyncapi+=("$rel") ;;
      contracts/common/*|contracts/.spectral.yaml)
        # Un cambio compartido afecta a todos: lint completo.
        exec "$0" ;;
      *) ;; # fuera de contracts/: se ignora
    esac
  done
fi

if [ "${#openapi[@]}" -eq 0 ] && [ "${#asyncapi[@]}" -eq 0 ]; then
  echo "lint-contracts: nada que lintear"
  exit 0
fi

status=0
fail() { status=1; }

if [ "${#openapi[@]}" -gt 0 ]; then
  echo "== spectral (${#openapi[@]} OpenAPI, reglas contracts/.spectral.yaml)"
  # shellcheck disable=SC2086
  $SPECTRAL lint "${openapi[@]}" -r contracts/.spectral.yaml -f stylish --fail-severity=error
  rc=$?; [ $rc -eq 0 ] || { [ $rc -eq 127 ] && exit 127; fail; }

  echo "== redocly (${#openapi[@]} OpenAPI)"
  # shellcheck disable=SC2086
  $REDOCLY lint "${openapi[@]}" --format=stylish
  rc=$?; [ $rc -eq 0 ] || { [ $rc -eq 127 ] && exit 127; fail; }
fi

if [ "${#asyncapi[@]}" -gt 0 ]; then
  echo "== asyncapi validate (${#asyncapi[@]} AsyncAPI)"
  for f in "${asyncapi[@]}"; do
    # shellcheck disable=SC2086
    out="$($ASYNCAPI validate "$f" 2>&1)"; rc=$?
    [ $rc -eq 127 ] && exit 127
    if [ $rc -eq 0 ] && grep -q "is valid" <<<"$out"; then
      echo "ok   $f"
    else
      echo "FAIL $f"
      grep -v -e "npm WARN" -e "eprecat" -e "punycode" <<<"$out" | sed 's/^/     /'
      fail
    fi
  done
fi

if [ $status -eq 0 ]; then
  echo "lint-contracts: 0 errores (${#openapi[@]} OpenAPI, ${#asyncapi[@]} AsyncAPI)"
else
  echo "lint-contracts: HAY ERRORES. Reglas: contracts/.spectral.yaml y v4 §11; skill coin-contracts." >&2
fi
exit $status
