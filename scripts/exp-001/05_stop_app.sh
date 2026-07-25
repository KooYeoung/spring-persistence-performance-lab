#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

main() {
  ensure_directories

  if [[ ! -f "$EXP001_PID_FILE" ]]; then
    log "PID 파일이 없습니다. 종료할 application process가 없습니다."
    return
  fi

  local pid
  pid="$(cat "$EXP001_PID_FILE")"
  if [[ "$pid" == "" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
    warn "PID가 실행 중이 아닙니다. PID 파일을 정리합니다: $EXP001_PID_FILE"
    rm -f "$EXP001_PID_FILE"
    return
  fi

  log "application 정상 종료 signal을 보냅니다. PID: $pid"
  kill "$pid"

  local deadline=$((SECONDS + 30))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      rm -f "$EXP001_PID_FILE"
      log "application이 정상 종료되었습니다."
      return
    fi
    sleep 1
  done

  warn "정상 종료 timeout으로 강제 종료합니다. PID: $pid"
  kill -9 "$pid"
  rm -f "$EXP001_PID_FILE"
}

main "$@"
