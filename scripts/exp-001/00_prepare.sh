#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

main() {
  assert_project_root
  ensure_directories

  if [[ ! -f "$EXP001_ENV_FILE" ]]; then
    cp "$EXP001_SCRIPT_DIR/.env.example" "$EXP001_ENV_FILE"
    log ".env 파일을 생성했습니다: $EXP001_ENV_FILE"
  else
    log "기존 .env 파일을 보존합니다: $EXP001_ENV_FILE"
  fi

  log "공식 실행 전 .env 값을 확인하세요. destructive reset은 ALLOW_DESTRUCTIVE_RESET=true일 때만 허용됩니다."

  local script_file
  for script_file in "$EXP001_SCRIPT_DIR"/*.sh; do
    if [[ ! -x "$script_file" ]]; then
      warn "실행 권한이 없으면 bash로 실행하세요: bash $script_file"
    fi
  done
}

main "$@"
