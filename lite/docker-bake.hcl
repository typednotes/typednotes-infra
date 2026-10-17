// Build every service from its own source Dockerfile, then assemble their
// artifacts. BuildKit shares stages and no intermediate images are published.
variable "APP_REF" { default = "v0.11.0" }
variable "LEDGER_REF" { default = "v0.3.7" }
variable "LIAISON_REF" { default = "v0.6.3" }
variable "SECRETS_REF" { default = "v1.3.0" }
variable "LODE_REF" { default = "v0.5.0" }
variable "LUN_REF" { default = "v0.4.2" }
variable "LITE_IMAGE" { default = "ghcr.io/typednotes/typednotes-lite:latest" }

group "default" { targets = ["lite"] }

target "_platform" { platforms = ["linux/amd64"] }

target "app" {
  inherits = ["_platform"]
  context = "https://github.com/typednotes/typednotes.git#${APP_REF}"
  cache-from = ["type=gha,scope=lite-app"]
  cache-to = ["type=gha,scope=lite-app,mode=max"]
}
target "ledger" {
  inherits = ["_platform"]
  context = "https://github.com/typednotes/ledger.git#${LEDGER_REF}"
  cache-from = ["type=gha,scope=lite-ledger"]
  cache-to = ["type=gha,scope=lite-ledger,mode=max"]
}
target "liaison" {
  inherits = ["_platform"]
  context = "https://github.com/typednotes/liaison.git#${LIAISON_REF}"
  cache-from = ["type=gha,scope=lite-liaison"]
  cache-to = ["type=gha,scope=lite-liaison,mode=max"]
}
target "vault" {
  inherits = ["_platform"]
  context = "https://github.com/typednotes/secrets.git#${SECRETS_REF}"
  cache-from = ["type=gha,scope=lite-vault"]
  cache-to = ["type=gha,scope=lite-vault,mode=max"]
}
target "lode" {
  inherits = ["_platform"]
  context = "https://github.com/typednotes/lode.git#${LODE_REF}"
  cache-from = ["type=gha,scope=lite-lode"]
  cache-to = ["type=gha,scope=lite-lode,mode=max"]
}
target "lun" {
  inherits = ["_platform"]
  context = "https://github.com/typednotes/lun.git#${LUN_REF}"
  cache-from = ["type=gha,scope=lite-lun"]
  cache-to = ["type=gha,scope=lite-lun,mode=max"]
}
target "lite" {
  inherits = ["_platform"]
  context = "."
  dockerfile = "lite/Dockerfile"
  contexts = {
    app = "target:app"
    ledger = "target:ledger"
    liaison = "target:liaison"
    vault = "target:vault"
    lode = "target:lode"
    lun = "target:lun"
  }
  tags = [LITE_IMAGE]
  cache-from = ["type=gha,scope=lite"]
  cache-to = ["type=gha,scope=lite,mode=max"]
  labels = {
    "org.opencontainers.image.source" = "https://github.com/typednotes/typednotes-infra"
    "org.opencontainers.image.description" = "Typednotes Lite: app, ledger, liaison, vault, Lode and Lun"
    "com.typednotes.app.ref" = APP_REF
    "com.typednotes.ledger.ref" = LEDGER_REF
    "com.typednotes.liaison.ref" = LIAISON_REF
    "com.typednotes.secrets.ref" = SECRETS_REF
    "com.typednotes.lode.ref" = LODE_REF
    "com.typednotes.lun.ref" = LUN_REF
  }
}
