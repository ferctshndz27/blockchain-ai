# Imagen del agente de lint de contratos para Jenkins. Mismas versiones de linters que
# .github/workflows/contracts.yml: al cambiarlas, cámbialas en los dos sitios.
FROM node:22.23.3-bookworm-slim

RUN npm install -g --no-audit --no-fund \
      @stoplight/spectral-cli@6.17.0 \
      @redocly/cli@2.57.0 \
      @asyncapi/cli@2.17.0 \
 && npm cache clean --force
