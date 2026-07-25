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
    clear_app_state
    return
  fi

  require_command jps

  local expected_pid
  local expected_jar
  local expected_jar_name
  local expected_profile
  expected_pid="$(metadata_value PID)" || die "application metadata에서 PID를 찾지 못했습니다. signal을 보내지 않습니다."
  expected_jar="$(metadata_value BOOT_JAR)" || die "application metadata에서 BOOT_JAR를 찾지 못했습니다. signal을 보내지 않습니다."
  expected_jar_name="$(metadata_value BOOT_JAR_NAME)" || die "application metadata에서 BOOT_JAR_NAME을 찾지 못했습니다. signal을 보내지 않습니다."
  expected_profile="$(metadata_value SPRING_PROFILE)" || die "application metadata에서 SPRING_PROFILE을 찾지 못했습니다. signal을 보내지 않습니다."

  [[ "$pid" == "$expected_pid" ]] || die "PID 파일과 metadata의 PID가 일치하지 않습니다. signal을 보내지 않습니다."
  [[ "$expected_profile" == "exp001" ]] || die "metadata의 Spring profile이 exp001이 아닙니다. signal을 보내지 않습니다: $expected_profile"

  if ! is_expected_app_process "$pid" "$expected_jar" "$expected_jar_name" "$expected_profile"; then
    die "PID가 기대한 EXP-001 application JVM과 일치하지 않습니다. PID 재사용 가능성이 있어 signal을 보내지 않습니다: $pid"
  fi

  log "application 정상 종료 signal을 보냅니다. PID: $pid"
  kill "$pid"

  local deadline=$((SECONDS + 30))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      clear_app_state
      log "application이 정상 종료되었습니다."
      return
    fi
    if ! is_expected_app_process "$pid" "$expected_jar" "$expected_jar_name" "$expected_profile"; then
      die "종료 대기 중 PID가 기대한 process와 달라졌습니다. 강제 종료하지 않습니다: $pid"
    fi
    sleep 1
  done

  if ! is_expected_app_process "$pid" "$expected_jar" "$expected_jar_name" "$expected_profile"; then
    die "강제 종료 직전 PID가 기대한 process와 달라졌습니다. 강제 종료하지 않습니다: $pid"
  fi

  warn "정상 종료 timeout으로 강제 종료합니다. PID: $pid"
  kill -9 "$pid"
  clear_app_state
}

main "$@"
