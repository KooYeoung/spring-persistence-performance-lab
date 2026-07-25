#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

main() {
  require_command bash
  require_command java
  require_command curl
  assert_project_root
  ensure_directories

  if [[ -f "$EXP001_PID_FILE" ]]; then
    local existing_pid
    existing_pid="$(cat "$EXP001_PID_FILE")"
    if [[ "$existing_pid" != "" ]] && kill -0 "$existing_pid" >/dev/null 2>&1; then
      die "이미 실행 중인 application PID가 있습니다: $existing_pid"
    fi
    rm -f "$EXP001_PID_FILE"
  fi

  local current_status
  current_status="$(http_status "$BASE_URL/internal/exp-001/jpa")"
  if [[ "$current_status" != "000" ]]; then
    die "BASE_URL에 이미 응답하는 process가 있습니다. HTTP status: $current_status"
  fi

  log "bootJar를 생성합니다."
  (cd "$PROJECT_ROOT_ABS" && bash ./gradlew --no-daemon --max-workers=1 bootJar)

  local boot_jar
  boot_jar="$(find "$PROJECT_ROOT_ABS/build/libs" -maxdepth 1 -type f -name "*.jar" ! -name "*plain.jar" | sort | tail -n 1)"
  [[ "$boot_jar" != "" ]] || die "실행 가능한 boot jar를 찾지 못했습니다."

  local server_port
  server_port="$(configured_server_port)"

  log "application을 exp001 profile로 시작합니다. log: $EXP001_APP_LOG"
  (
    cd "$PROJECT_ROOT_ABS"
    SERVER_PORT="$server_port" nohup java \
      -Xms2g \
      -Xmx2g \
      -XX:+UseG1GC \
      -Duser.timezone=UTC \
      -jar "$boot_jar" \
      --spring.profiles.active="$SPRING_PROFILE" \
      >"$EXP001_APP_LOG" 2>&1 &
    printf '%s\n' "$!" >"$EXP001_PID_FILE"
  )

  local pid
  pid="$(cat "$EXP001_PID_FILE")"
  log "application PID: $pid"

  local deadline=$((SECONDS + 120))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if [[ "$(http_status "$BASE_URL/internal/exp-001/jpa")" == "405" ]]; then
      log "exp001 profiling endpoint 등록을 확인했습니다."
      return
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      die "application process가 시작 중 종료되었습니다. log를 확인하세요: $EXP001_APP_LOG"
    fi
    sleep 2
  done

  die "startup timeout이 발생했습니다. log를 확인하세요: $EXP001_APP_LOG"
}

main "$@"
