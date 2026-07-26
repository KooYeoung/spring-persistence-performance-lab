#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
initialize_exp001

show_help() {
  cat <<'EOF'
EXP-001 macOS harness

Usage: ./scripts/exp-001/macos/exp001.sh <action> [run-directory]

Actions:
  prepare    .env, .state, result root, portable jq와 locked JDK를 준비한다.
  start      bootJar를 생성하고 exp001 profile application JVM을 시작한다.
  check      endpoint, Docker Compose PostgreSQL identity와 Safety Gate를 확인한다.
  benchmark  warm-up과 official 6 round를 실행한다.
  summary    official JSON 12개를 검증한 뒤 summary.md를 생성한다.
  stop       state가 가리키는 exp001 application JVM만 종료한다.
  help       도움말을 출력한다.
EOF
}

prepare() {
  assert_project_root
  ensure_directories
  require_command git

  if [[ ! -f "$EXP001_ENV_FILE" ]]; then
    cp "$EXP001_ROOT/.env.example" "$EXP001_ENV_FILE"
    log ".env 파일을 생성했습니다: $EXP001_ENV_FILE"
  else
    log "기존 .env 파일을 보존합니다: $EXP001_ENV_FILE"
  fi

  install_or_verify_jq
  resolve_locked_jdk --allow-download
  require_docker_compose

  if [[ ! -x "$SCRIPT_DIR/exp001.sh" ]]; then
    warn "실행 권한이 없으면 bash로 실행하세요: bash $SCRIPT_DIR/exp001.sh"
  fi

  log "공식 실행 전 .env 값을 확인하세요. destructive reset은 ALLOW_DESTRUCTIVE_RESET=true일 때만 허용됩니다."
}

start() {
  assert_project_root
  ensure_directories
  resolve_locked_jdk
  require_command git
  require_command curl
  require_docker_compose
  require_jq >/dev/null

  [[ "$SPRING_PROFILE" == "exp001" ]] || die "EXP-001 application은 exp001 profile로만 시작할 수 있습니다: $SPRING_PROFILE"

  if [[ -f "$EXP001_APPLICATION_STATE_FILE" ]]; then
    local existing_pid
    existing_pid="$(state_value '.pid')" || die "application state JSON을 읽을 수 없습니다. 시작하지 않습니다: $EXP001_APPLICATION_STATE_FILE"
    if kill -0 "$existing_pid" >/dev/null 2>&1; then
      if is_expected_application_process; then
        die "이미 실행 중인 EXP-001 application PID가 있습니다: $existing_pid"
      fi
      die "stale 또는 mismatched state입니다. PID 재사용 가능성이 있어 시작하지 않습니다: $EXP001_APPLICATION_STATE_FILE"
    fi
    clear_application_state
  fi

  local current_status
  current_status="$(http_status "$BASE_URL/internal/exp-001/jpa")"
  if [[ "$current_status" != "000" ]]; then
    die "BASE_URL에 이미 응답하는 process가 있습니다. HTTP status: $current_status"
  fi

  [[ -x "$PROJECT_ROOT_ABS/gradlew" ]] || die "Gradle Wrapper 실행 권한을 확인하세요: $PROJECT_ROOT_ABS/gradlew"
  log "bootJar를 생성합니다."
  (cd "$PROJECT_ROOT_ABS" && run_with_locked_jdk ./gradlew --no-daemon --max-workers=1 bootJar)

  local jars=()
  local jar
  local nullglob_was_set=0
  if shopt -q nullglob; then
    nullglob_was_set=1
  fi
  shopt -s nullglob
  for jar in "$PROJECT_ROOT_ABS"/build/libs/*.jar; do
    case "$(basename "$jar")" in
      *-plain.jar) continue ;;
    esac
    [[ -f "$jar" ]] && jars+=("$jar")
  done
  if [[ "$nullglob_was_set" -eq 0 ]]; then
    shopt -u nullglob
  fi

  [[ "${#jars[@]}" -eq 1 ]] || die "실행 가능한 boot jar가 정확히 하나가 아닙니다: ${#jars[@]}"
  local boot_jar
  boot_jar="$(cd "$(dirname "${jars[0]}")" && pwd -P)/$(basename "${jars[0]}")"

  local server_port
  server_port="$(configured_server_port)"

  log "application을 exp001 profile로 시작합니다. log: $EXP001_APPLICATION_LOG"
  local original_dir
  local pid
  original_dir="$(pwd -P)"
  cd "$PROJECT_ROOT_ABS"
  SERVER_PORT="$server_port" nohup "$LOCKED_JDK_JAVA" \
    -Xms2g \
    -Xmx2g \
    -XX:+UseG1GC \
    -Duser.timezone=UTC \
    -jar "$boot_jar" \
    --spring.profiles.active="$SPRING_PROFILE" \
    >"$EXP001_APPLICATION_LOG" 2>&1 &
  pid="$!"
  cd "$original_dir"

  sleep 1
  write_application_state "$pid" "$boot_jar"
  log "application PID: $pid"

  local deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if [[ "$(http_status "$BASE_URL/internal/exp-001/jpa")" == "405" ]]; then
      log "exp001 profiling endpoint 등록을 확인했습니다."
      return
    fi
    if ! is_expected_application_process; then
      local failure_message
      failure_message="application process가 시작 중 종료되었거나 identity가 변경되었습니다. log를 확인하세요: $EXP001_APPLICATION_LOG"
      cleanup_startup_failure "$failure_message"
      die "$failure_message"
    fi
    sleep 2
  done

  local failure_message
  failure_message="startup timeout이 발생했습니다. log를 확인하세요: $EXP001_APPLICATION_LOG"
  cleanup_startup_failure "$failure_message"
  die "$failure_message"
}

check_environment() {
  assert_project_root
  ensure_directories
  resolve_locked_jdk
  require_command git
  require_command curl
  require_docker_compose
  require_jq >/dev/null

  log "project root: $PROJECT_ROOT_ABS"
  log "result root: $RESULT_ROOT_ABS"
  log "PostgreSQL service: $EXP001_POSTGRES_SERVICE"

  require_app_endpoint_registered
  log "application reachable: $BASE_URL"

  require_db_identity_gate
  log "PostgreSQL configured identity와 actual identity를 확인했습니다."
  log "official timing 중 debugger, SQL logging, Hibernate statistics, profiler는 OFF 상태로 운영하세요."
}

run_step() {
  local path="$1"
  local output_file="$2"
  local label="$3"
  local temp_file="${output_file}.tmp.$$"

  [[ ! -e "$output_file" ]] || die "final output file이 이미 존재합니다: $output_file"
  rm -f -- "$temp_file"

  reset_benchmark_table
  assert_benchmark_table_empty
  log "$label: $path endpoint 호출"

  if ! call_benchmark_endpoint "$path" "$temp_file" "$EXPECTED_INPUT_COUNT"; then
    rm -f -- "$temp_file"
    die "HTTP 호출 실패로 결과를 final path에 반영하지 않았습니다: $output_file"
  fi

  if ! verify_response "$path" "$temp_file" "$EXPECTED_INPUT_COUNT"; then
    rm -f -- "$temp_file"
    die "response 검증 실패로 결과를 final path에 반영하지 않았습니다: $output_file"
  fi

  [[ ! -e "$output_file" ]] || die "검증 후 final output file이 이미 존재합니다: $output_file"
  if ! mv -- "$temp_file" "$output_file"; then
    rm -f -- "$temp_file"
    die "검증된 temporary JSON을 final path로 이동하지 못했습니다: $output_file"
  fi

  cooldown "$COOLDOWN_SECONDS"
}

benchmark() {
  assert_project_root
  ensure_directories
  resolve_locked_jdk
  require_command git
  require_command curl
  require_docker_compose
  require_jq >/dev/null
  assert_official_settings
  require_app_endpoint_registered

  local run_id
  run_id="$(new_run_id)"
  local run_dir="$RESULT_ROOT_ABS/$run_id"
  local warmup_dir="$run_dir/warmup"
  local official_dir="$run_dir/official"
  [[ ! -e "$run_dir" ]] || die "run directory가 이미 존재합니다: $run_dir"
  mkdir -p "$warmup_dir" "$official_dir"

  log "EXP-001 run ID: $run_id"
  log "warm-up 시작"
  run_step "jpa" "$warmup_dir/01-jpa-warmup.json" "warm-up JPA"
  run_step "jdbc" "$warmup_dir/02-jdbc-warmup.json" "warm-up JDBC"

  log "official rounds 시작"
  local round
  for ((round = 1; round <= 6; round++)); do
    local round_text
    round_text="$(printf '%02d' "$round")"
    if (( round % 2 == 1 )); then
      run_step "jpa" "$official_dir/round-$round_text-01-jpa.json" "round $round position 1"
      run_step "jdbc" "$official_dir/round-$round_text-02-jdbc.json" "round $round position 2"
    else
      run_step "jdbc" "$official_dir/round-$round_text-01-jdbc.json" "round $round position 1"
      run_step "jpa" "$official_dir/round-$round_text-02-jpa.json" "round $round position 2"
    fi
  done

  log "official JSON 저장 완료: $official_dir"
}

latest_run_dir() {
  local latest=""
  local entry
  local name
  local nullglob_was_set=0
  if shopt -q nullglob; then
    nullglob_was_set=1
  fi
  shopt -s nullglob
  for entry in "$RESULT_ROOT_ABS"/*; do
    [[ -d "$entry" ]] || continue
    name="$(basename "$entry")"
    if [[ "$latest" == "" || "$name" > "$latest" ]]; then
      latest="$name"
    fi
  done
  if [[ "$nullglob_was_set" -eq 0 ]]; then
    shopt -u nullglob
  fi

  if [[ "$latest" != "" ]]; then
    printf '%s\n' "$RESULT_ROOT_ABS/$latest"
  fi
}

resolve_run_dir() {
  local run_dir="$1"
  if [[ "$run_dir" == "" ]]; then
    latest_run_dir
    return
  fi
  if [[ "$run_dir" == /* ]]; then
    printf '%s\n' "$run_dir"
  else
    if [[ -d "$run_dir" ]]; then
      (cd "$run_dir" && pwd -P)
    else
      printf '%s\n' "$PROJECT_ROOT_ABS/$run_dir"
    fi
  fi
}

summary() {
  assert_project_root
  ensure_directories
  require_jq >/dev/null
  assert_official_settings

  local run_dir
  run_dir="$(resolve_run_dir "${1:-}")"
  [[ "$run_dir" != "" ]] || die "summary를 생성할 run directory를 찾지 못했습니다."
  [[ -d "$run_dir/official" ]] || die "official JSON directory가 없습니다: $run_dir/official"

  local official_files=()
  local file
  local nullglob_was_set=0
  if shopt -q nullglob; then
    nullglob_was_set=1
  fi
  shopt -s nullglob
  for file in "$run_dir"/official/*.json; do
    [[ -f "$file" ]] && official_files+=("$file")
  done
  if [[ "$nullglob_was_set" -eq 0 ]]; then
    shopt -u nullglob
  fi

  [[ "${#official_files[@]}" -eq 12 ]] || die "official JSON 파일 수가 정확히 12개가 아닙니다: ${#official_files[@]}"

  local summary_file="$run_dir/summary.md"
  local temp_summary="${summary_file}.tmp.$$"
  local jq_bin
  jq_bin="$(require_jq)"
  rm -f -- "$temp_summary"

  if ! "$jq_bin" -r --argjson expectedCount "$EXPECTED_INPUT_COUNT" -s -f "$EXP001_SUMMARY_FILTER" "${official_files[@]}" >"$temp_summary"; then
    rm -f -- "$temp_summary"
    die "official JSON gate 또는 summary 계산에 실패했습니다."
  fi

  mv -- "$temp_summary" "$summary_file"
  log "summary 생성 완료: $summary_file"
}

stop_app() {
  ensure_directories

  if [[ ! -f "$EXP001_APPLICATION_STATE_FILE" ]]; then
    log "application state 파일이 없습니다. 종료할 application process가 없습니다."
    return
  fi

  local pid
  pid="$(state_value '.pid')" || die "application state JSON을 읽을 수 없습니다. signal을 보내지 않습니다."

  if ! kill -0 "$pid" >/dev/null 2>&1; then
    warn "PID가 실행 중이 아닙니다. state 파일을 정리합니다: $EXP001_APPLICATION_STATE_FILE"
    clear_application_state
    return
  fi

  if ! is_expected_application_process; then
    die "PID가 기대한 EXP-001 application JVM과 일치하지 않습니다. PID 재사용 가능성이 있어 signal을 보내지 않습니다: $pid"
  fi

  log "application 정상 종료 signal을 보냅니다. PID: $pid"
  kill "$pid"

  local deadline=$((SECONDS + STOP_TIMEOUT_SECONDS))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      clear_application_state
      log "application이 정상 종료되었습니다."
      return
    fi
    if ! is_expected_application_process; then
      die "종료 대기 중 PID가 기대한 process와 달라졌습니다. 강제 종료하지 않습니다: $pid"
    fi
    sleep 1
  done

  if ! is_expected_application_process; then
    die "강제 종료 직전 PID가 기대한 process와 달라졌습니다. 강제 종료하지 않습니다: $pid"
  fi

  warn "정상 종료 timeout으로 강제 종료합니다. PID: $pid"
  kill -9 "$pid"
  clear_application_state
}

action="${1:-help}"
shift || true

case "$action" in
  prepare) prepare "$@" ;;
  start) start "$@" ;;
  check) check_environment "$@" ;;
  benchmark) benchmark "$@" ;;
  summary) summary "$@" ;;
  stop) stop_app "$@" ;;
  help|-h|--help) show_help ;;
  *)
    show_help
    die "알 수 없는 action입니다: $action"
    ;;
esac
