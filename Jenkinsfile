// CI local de Coin en Jenkins (Docker del equipo). Es el mismo gate que el hook pre-commit y que GitHub Actions:
// scripts/lint-contracts.sh es la única fuente de verdad del lint de contratos.
//
// Reglas para tocar este archivo (las lee Hermes en la skill jenkins-local):
//  - Pipeline declarativo; cada etapa lleva su agente. Imágenes con versión fija.
//  - Agentes en contenedor siempre con '--cpus=4 -m 4g' (no quitarle recursos al modelo local).
//  - Sin --privileged, sin montar /var/run/docker.sock ni rutas fuera del workspace, sin secretos en claro.
//  - La lógica vive en scripts/*.sh (se prueba en local); el Jenkinsfile solo la orquesta.
pipeline {
  agent none

  options {
    timestamps()
    timeout(time: 15, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
    disableConcurrentBuilds()
  }

  stages {
    stage('Contratos: lint') {
      agent {
        dockerfile {
          dir 'ci'
          filename 'contracts-lint.Dockerfile'
          args '--cpus=4 -m 4g'
        }
      }
      steps {
        sh 'scripts/lint-contracts.sh'
      }
    }

    // Etapas preparadas para cuando haya código (v4 §12.2: services/, edge/, libs/). Hoy se saltan.
    stage('Build (pendiente: aún no hay código)') {
      when { beforeAgent true; expression { return false } }
      agent any
      steps { echo 'Construir imágenes de services/ con el Dockerfile de cada servicio.' }
    }
    stage('Test (pendiente: aún no hay código)') {
      when { beforeAgent true; expression { return false } }
      agent any
      steps { echo 'Pruebas unitarias y de contrato (Prism) de cada servicio.' }
    }
    stage('Deploy (pendiente: aún no hay código)') {
      when { beforeAgent true; allOf { branch 'main'; expression { return false } } }
      agent any
      steps { echo 'Despliegue local con docker compose (solo main).' }
    }
  }
}
