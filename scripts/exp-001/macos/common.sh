#!/usr/bin/env bash
set -Eeuo pipefail

EXP001_MACOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXP001_ROOT="$(cd "$EXP001_MACOS_DIR/.." && pwd -P)"
EXP001_ENV_FILE="$EXP001_ROOT/.env"
EXP001_STATE_DIR="$EXP001_ROOT/.state"
EXP001_TOOLS_DIR="$EXP001_ROOT/.tools"
EXP001_APPLICATION_STATE_FILE="$EXP001_STATE_DIR/application.json"
EXP001_APPLICATION_LOG="$EXP001_STATE_DIR/application.log"
EXP001_JQ_LOCK_FILE="$EXP001_ROOT/tools/jq.lock"
EXP001_VALIDATE_RESPONSE_FILTER="$EXP001_ROOT/shared/validate-response.jq"
EXP001_SUMMARY_FILTER="$EXP001_ROOT/shared/summary.jq"
EXP001_POSTGRES_SERVICE="persistence-lab-postgres"
EXP001_PLATFORM_NAME="macos"

PROJECT_ROOT="../.."
BASE_URL="http://localhost:8080"
DB_HOST="localhost"
DB_PORT="55432"
DB_NAME="persistence_lab"
DB_USER="lab_user"
DB_PASSWORD="lab_password"
SPRING_PROFILE="exp001"
EXPECTED_INPUT_COUNT="50000"
OFFICIAL_ROUNDS="6"
COOLDOWN_SECONDS="10"
REQUEST_TIMEOUT_SECONDS="600"
STARTUP_TIMEOUT_SECONDS="180"
STOP_TIMEOUT_SECONDS="20"
ALLOW_DESTRUCTIVE_RESET="false"
RESULT_ROOT="results/exp-001"
PROJECT_ROOT_ABS=""
RESULT_ROOT_ABS=""

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

warn() {
  printf '[%s] WARN: %s\n' "$(timestamp)" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >&2
  exit 1
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

set_config_value() {
  local key="$1"
  local value="$2"

  case "$key" in
    PROJECT_ROOT) PROJECT_ROOT="$value" ;;
    BASE_URL) BASE_URL="$value" ;;
    DB_HOST) DB_HOST="$value" ;;
    DB_PORT) DB_PORT="$value" ;;
    DB_NAME) DB_NAME="$value" ;;
    DB_USER) DB_USER="$value" ;;
    DB_PASSWORD) DB_PASSWORD="$value" ;;
    SPRING_PROFILE) SPRING_PROFILE="$value" ;;
    EXPECTED_INPUT_COUNT) EXPECTED_INPUT_COUNT="$value" ;;
    OFFICIAL_ROUNDS) OFFICIAL_ROUNDS="$value" ;;
    COOLDOWN_SECONDS) COOLDOWN_SECONDS="$value" ;;
    REQUEST_TIMEOUT_SECONDS) REQUEST_TIMEOUT_SECONDS="$value" ;;
    STARTUP_TIMEOUT_SECONDS) STARTUP_TIMEOUT_SECONDS="$value" ;;
    STOP_TIMEOUT_SECONDS) STOP_TIMEOUT_SECONDS="$value" ;;
    ALLOW_DESTRUCTIVE_RESET) ALLOW_DESTRUCTIVE_RESET="$value" ;;
    RESULT_ROOT) RESULT_ROOT="$value" ;;
    *) warn "알 수 없는 .env key를 무시합니다: $key" ;;
  esac
}

load_env_file() {
  local line
  local key
  local value

  [[ -f "$EXP001_ENV_FILE" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ "$line" == "" || "${line#\#}" != "$line" ]] && continue
    [[ "$line" == *"="* ]] || die "KEY=VALUE 형식이 아닌 line입니다: $EXP001_ENV_FILE"

    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "허용되지 않는 key 형식입니다: $key"
    set_config_value "$key" "$value"
  done <"$EXP001_ENV_FILE"
}

validate_result_root_value() {
  local value="$1"
  local segment

  [[ "$value" != "" ]] || die "RESULT_ROOT는 비어 있을 수 없습니다."
  [[ "$value" != "." ]] || die "RESULT_ROOT는 project root 자체를 가리킬 수 없습니다."
  [[ "$value" != /* ]] || die "RESULT_ROOT는 absolute path일 수 없습니다: $value"
  [[ "$value" != "~"* ]] || die "RESULT_ROOT는 home shortcut으로 시작할 수 없습니다: $value"
  [[ "$value" != *\\* ]] || die "RESULT_ROOT는 forward slash만 사용할 수 있습니다: $value"
  [[ ! "$value" =~ ^[A-Za-z]: ]] || die "RESULT_ROOT는 Windows drive path일 수 없습니다: $value"
  [[ "$value" != *"//"* && "$value" != */ ]] || die "RESULT_ROOT에는 빈 path segment가 포함될 수 없습니다: $value"

  local IFS='/'
  for segment in $value; do
    [[ "$segment" != "" ]] || die "RESULT_ROOT에는 빈 path segment가 포함될 수 없습니다: $value"
    [[ "$segment" != "." && "$segment" != ".." ]] || die "RESULT_ROOT에는 . 또는 .. path segment가 포함될 수 없습니다: $value"
  done
}

resolve_safe_result_root() {
  local value="$1"
  local root_physical="$PROJECT_ROOT_ABS"
  local current="$root_physical"
  local resolved_candidate="$root_physical"
  local missing_started=0
  local segment
  local next

  validate_result_root_value "$value"

  local IFS='/'
  for segment in $value; do
    if [[ "$missing_started" -eq 1 ]]; then
      resolved_candidate="$resolved_candidate/$segment"
      continue
    fi

    next="$current/$segment"
    if [[ -e "$next" || -L "$next" ]]; then
      [[ -d "$next" ]] || die "RESULT_ROOT 경로에 directory가 아닌 항목이 있습니다: $next"
      [[ ! -L "$next" ]] || die "RESULT_ROOT 경로에 symlink가 포함되어 있습니다: $next"
      current="$(cd "$next" && pwd -P)" || die "RESULT_ROOT physical path를 확인하지 못했습니다: $next"
      [[ "$current" == "$root_physical" || "$current" == "$root_physical"/* ]] || die "RESULT_ROOT는 project root 내부여야 합니다: $value"
      resolved_candidate="$current"
    else
      missing_started=1
      resolved_candidate="$current/$segment"
    fi
  done

  [[ "$resolved_candidate" != "$root_physical" ]] || die "RESULT_ROOT는 project root 자체를 가리킬 수 없습니다."
  [[ "$resolved_candidate" == "$root_physical"/* ]] || die "RESULT_ROOT는 project root 내부여야 합니다: $value"
  printf '%s\n' "$resolved_candidate"
}

initialize_exp001() {
  load_env_file
  PROJECT_ROOT_ABS="$(cd "$EXP001_ROOT/$PROJECT_ROOT" && pwd -P)"
  RESULT_ROOT_ABS="$(resolve_safe_result_root "$RESULT_ROOT")"
}

require_command() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "필수 command를 찾을 수 없습니다: $name"
}

require_docker_compose() {
  require_command docker
  docker compose version >/dev/null 2>&1 || die "docker compose를 사용할 수 없습니다. Docker Desktop과 Compose plugin을 확인하세요."
}

ensure_directories() {
  mkdir -p "$EXP001_STATE_DIR" "$EXP001_TOOLS_DIR" "$RESULT_ROOT_ABS"
}

assert_project_root() {
  [[ -f "$PROJECT_ROOT_ABS/settings.gradle" ]] || die "project root에서 settings.gradle을 찾을 수 없습니다: $PROJECT_ROOT_ABS"
  [[ -f "$PROJECT_ROOT_ABS/AGENTS.md" ]] || die "project root에서 AGENTS.md를 찾을 수 없습니다: $PROJECT_ROOT_ABS"
}

assert_java21() {
  require_command java
  local version_text
  version_text="$(java -version 2>&1 | sed -n '1p')"
  case "$version_text" in
    *'version "21.'*) ;;
    *) die "Java 21 runtime이 필요합니다. 현재 java -version: $version_text" ;;
  esac
}

configured_server_port() {
  if [[ "${SERVER_PORT:-}" != "" ]]; then
    printf '%s\n' "$SERVER_PORT"
    return
  fi

  local without_scheme="${BASE_URL#*://}"
  local host_port="${without_scheme%%/*}"
  if [[ "$host_port" == *:* ]]; then
    printf '%s\n' "${host_port##*:}"
  else
    printf '8080\n'
  fi
}

lock_value() {
  local expected_key="$1"
  local line
  local key
  local value

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ "$line" == "" || "${line#\#}" != "$line" ]] && continue
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    if [[ "$key" == "$expected_key" ]]; then
      printf '%s\n' "$value"
      return
    fi
  done <"$EXP001_JQ_LOCK_FILE"

  return 1
}

jq_platform_key() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64) printf 'macos_x64\n' ;;
    arm64) printf 'macos_arm64\n' ;;
    *) die "지원하지 않는 macOS architecture입니다: $machine" ;;
  esac
}

jq_path() {
  local platform_key="$1"
  case "$platform_key" in
    macos_x64) printf '%s\n' "$EXP001_TOOLS_DIR/macos-x64/jq" ;;
    macos_arm64) printf '%s\n' "$EXP001_TOOLS_DIR/macos-arm64/jq" ;;
    *) die "지원하지 않는 jq platform key입니다: $platform_key" ;;
  esac
}

sha256_file() {
  local file="$1"
  local checksum
  local ignored
  IFS=' ' read -r checksum ignored < <(shasum -a 256 "$file")
  printf '%s\n' "$checksum"
}

assert_jq_checksum() {
  local path="$1"
  local expected_sha="$2"
  local actual_sha

  [[ -f "$path" ]] || die "portable jq를 찾을 수 없습니다. 먼저 prepare를 실행하세요: $path"
  actual_sha="$(sha256_file "$path")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    rm -f -- "$path"
    die "portable jq checksum이 일치하지 않아 삭제했습니다. expected=$expected_sha actual=$actual_sha"
  fi
}

install_or_verify_jq() {
  require_command curl
  require_command shasum

  local platform_key
  local url
  local expected_sha
  local target
  local temp
  platform_key="$(jq_platform_key)"
  url="$(lock_value "${platform_key}_url")" || die "jq lock에서 URL을 찾지 못했습니다: ${platform_key}_url"
  expected_sha="$(lock_value "${platform_key}_sha256")" || die "jq lock에서 SHA-256을 찾지 못했습니다: ${platform_key}_sha256"
  target="$(jq_path "$platform_key")"
  mkdir -p "$(dirname "$target")"

  if [[ -f "$target" ]]; then
    assert_jq_checksum "$target" "$expected_sha"
    log "portable jq checksum 확인 완료: $target"
    return
  fi

  temp="${target}.tmp.$$"
  rm -f -- "$temp"
  log "portable jq를 다운로드합니다: jq $(lock_value version) $platform_key"
  if ! curl --fail --location --silent --show-error --output "$temp" "$url"; then
    rm -f -- "$temp"
    die "portable jq 다운로드에 실패했습니다."
  fi

  if [[ "$(sha256_file "$temp")" != "$expected_sha" ]]; then
    rm -f -- "$temp"
    die "downloaded jq checksum이 일치하지 않습니다."
  fi

  [[ ! -e "$target" ]] || die "portable jq final path가 이미 존재합니다: $target"
  chmod +x "$temp"
  mv -- "$temp" "$target"
  log "portable jq 준비 완료: $target"
}

require_jq() {
  local platform_key
  local expected_sha
  local target
  platform_key="$(jq_platform_key)"
  expected_sha="$(lock_value "${platform_key}_sha256")" || die "jq lock에서 SHA-256을 찾지 못했습니다: ${platform_key}_sha256"
  target="$(jq_path "$platform_key")"
  assert_jq_checksum "$target" "$expected_sha"
  printf '%s\n' "$target"
}

http_status() {
  local url="$1"
  curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 "$url" || printf '000'
}

require_app_endpoint_registered() {
  local status_code
  status_code="$(http_status "$BASE_URL/internal/exp-001/jpa")"
  [[ "$status_code" == "405" ]] || die "exp001 profiling endpoint가 확인되지 않습니다. expected HTTP 405, actual HTTP $status_code"
}

psql_query() {
  local sql="$1"
  local output

  if ! output="$(docker compose -f "$PROJECT_ROOT_ABS/docker-compose.yml" exec -T "$EXP001_POSTGRES_SERVICE" psql \
    --username "$DB_USER" \
    --dbname "$DB_NAME" \
    --no-align \
    --tuples-only \
    --no-psqlrc \
    --set ON_ERROR_STOP=1 \
    --command "$sql" | tr -d '\r')"; then
    die "container 내부 psql 실행에 실패했습니다. Docker Compose service를 확인하세요: $EXP001_POSTGRES_SERVICE"
  fi

  trim "$output"
}

psql_exec() {
  local sql="$1"

  docker compose -f "$PROJECT_ROOT_ABS/docker-compose.yml" exec -T "$EXP001_POSTGRES_SERVICE" psql \
    --username "$DB_USER" \
    --dbname "$DB_NAME" \
    --no-psqlrc \
    --set ON_ERROR_STOP=1 \
    --command "$sql" >/dev/null \
    || die "container 내부 psql 실행에 실패했습니다. Docker Compose service를 확인하세요: $EXP001_POSTGRES_SERVICE"
}

require_configured_db_gate() {
  [[ "$ALLOW_DESTRUCTIVE_RESET" == "true" ]] || die "ALLOW_DESTRUCTIVE_RESET가 true가 아니므로 reset과 run을 중단합니다."

  case "$DB_HOST" in
    localhost|127.0.0.1) ;;
    *) die "DB_HOST가 허용된 local host가 아닙니다: $DB_HOST" ;;
  esac

  [[ "$DB_PORT" == "55432" ]] || die "DB_PORT가 55432가 아닙니다: $DB_PORT"
  [[ "$DB_NAME" == "persistence_lab" ]] || die "DB_NAME이 persistence_lab이 아닙니다: $DB_NAME"
  [[ "$DB_USER" == "lab_user" ]] || die "DB_USER가 lab_user가 아닙니다: $DB_USER"
}

require_actual_db_gate() {
  local actual_database
  local actual_user
  local actual_isolation

  actual_database="$(psql_query "SELECT current_database();")"
  actual_user="$(psql_query "SELECT current_user;")"
  actual_isolation="$(psql_query "SHOW transaction_isolation;")"

  [[ "$actual_database" == "persistence_lab" ]] || die "current_database()가 persistence_lab이 아닙니다: $actual_database"
  [[ "$actual_user" == "lab_user" ]] || die "current_user가 lab_user가 아닙니다: $actual_user"
  [[ "$actual_isolation" == "read committed" ]] || die "transaction isolation이 read committed가 아닙니다: $actual_isolation"
}

require_db_safety_gate() {
  require_configured_db_gate
  require_actual_db_gate
}

reset_benchmark_table() {
  require_db_safety_gate
  psql_exec "TRUNCATE TABLE benchmark_record RESTART IDENTITY;"
}

assert_benchmark_table_empty() {
  local row_count
  row_count="$(psql_query "SELECT COUNT(*) FROM benchmark_record;")"
  [[ "$row_count" == "0" ]] || die "reset 이후 benchmark_record row count가 0이 아닙니다: $row_count"
}

verify_response() {
  local expected_path="$1"
  local file="$2"
  local expected_count="$3"
  local jq_bin

  jq_bin="$(require_jq)"
  "$jq_bin" -e --arg expectedPath "$expected_path" --argjson expectedCount "$expected_count" -f "$EXP001_VALIDATE_RESPONSE_FILTER" "$file" >/dev/null \
    || die "response JSON gate를 통과하지 못했습니다: $file"
}

call_benchmark_endpoint() {
  local path="$1"
  local output_file="$2"
  local count="$3"
  local url="$BASE_URL/internal/exp-001/$path"
  local response_body

  response_body="$(curl \
    --silent \
    --show-error \
    --fail \
    --max-time "$REQUEST_TIMEOUT_SECONDS" \
    --header "Content-Type: application/json" \
    --data "{\"count\":$count}" \
    "$url")" || return 1

  printf '%s' "$response_body" >"$output_file"
}

cooldown() {
  local seconds="${1:-$COOLDOWN_SECONDS}"
  if [[ "$seconds" -gt 0 ]]; then
    log "cooldown ${seconds}s"
    sleep "$seconds"
  fi
}

short_git_sha() {
  git -C "$PROJECT_ROOT_ABS" rev-parse --short HEAD
}

new_run_id() {
  printf '%s-%s\n' "$(date -u +"%Y%m%dT%H%M%SZ")" "$(short_git_sha)"
}

process_command_line() {
  local pid="$1"
  ps -ww -p "$pid" -o command= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

process_start_identity() {
  local pid="$1"
  local command_name
  local command_line
  local start_value

  command_name="$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" || return 1
  command_line="$(process_command_line "$pid")" || return 1
  start_value="$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" || return 1

  [[ "$command_name" == "java" || "$command_name" == */java ]] || return 1
  [[ "$command_line" != "" && "$start_value" != "" ]] || return 1
  printf '%s|%s|%s\n' "$start_value" "$command_name" "$command_line"
}

write_application_state() {
  local pid="$1"
  local jar_path="$2"
  local identity
  local temp_file
  local jq_bin

  identity="$(process_start_identity "$pid")" || die "시작한 PID가 Java application으로 확인되지 않습니다: $pid"
  temp_file="$EXP001_APPLICATION_STATE_FILE.tmp.$$"
  jq_bin="$(require_jq)"

  "$jq_bin" -n \
    --argjson pid "$pid" \
    --arg processStartIdentity "$identity" \
    --arg jarPath "$jar_path" \
    --arg profile "$SPRING_PROFILE" \
    --arg baseUrl "$BASE_URL" \
    --arg platform "$EXP001_PLATFORM_NAME" \
    '{pid: $pid, processStartIdentity: $processStartIdentity, jarPath: $jarPath, profile: $profile, baseUrl: $baseUrl, platform: $platform}' \
    >"$temp_file"
  mv -- "$temp_file" "$EXP001_APPLICATION_STATE_FILE"
}

clear_application_state() {
  rm -f -- "$EXP001_APPLICATION_STATE_FILE" "$EXP001_STATE_DIR/app.pid" "$EXP001_STATE_DIR/application.metadata"
}

state_value() {
  local expression="$1"
  local jq_bin
  [[ -f "$EXP001_APPLICATION_STATE_FILE" ]] || return 1
  jq_bin="$(require_jq)"
  "$jq_bin" -er "$expression" "$EXP001_APPLICATION_STATE_FILE"
}

is_expected_application_process() {
  local pid
  local expected_identity
  local expected_jar
  local expected_profile
  local expected_base_url
  local expected_platform
  local live_identity
  local command_line

  pid="$(state_value '.pid')" || return 1
  expected_identity="$(state_value '.processStartIdentity')" || return 1
  expected_jar="$(state_value '.jarPath')" || return 1
  expected_profile="$(state_value '.profile')" || return 1
  expected_base_url="$(state_value '.baseUrl')" || return 1
  expected_platform="$(state_value '.platform')" || return 1

  [[ "$expected_platform" == "$EXP001_PLATFORM_NAME" ]] || return 1
  [[ "$expected_profile" == "exp001" ]] || return 1
  [[ "$expected_base_url" == "$BASE_URL" ]] || return 1

  live_identity="$(process_start_identity "$pid")" || return 1
  [[ "$live_identity" == "$expected_identity" ]] || return 1

  command_line="$(process_command_line "$pid")" || return 1
  [[ "$command_line" == *"$expected_jar"* ]] || return 1
  [[ "$command_line" == *"--spring.profiles.active=$expected_profile"* ]] || return 1
}

cleanup_startup_failure() {
  local reason="$1"
  local pid
  local deadline

  warn "startup 실패로 시작한 JVM 정리를 시도합니다: $reason"
  if [[ ! -f "$EXP001_APPLICATION_STATE_FILE" ]]; then
    warn "application state가 없어 cleanup할 process를 확인할 수 없습니다."
    return
  fi

  pid="$(state_value '.pid')" || {
    warn "application state JSON에서 PID를 읽을 수 없어 signal을 보내지 않습니다."
    return
  }

  if ! kill -0 "$pid" >/dev/null 2>&1; then
    clear_application_state
    warn "startup 실패 시점에 PID가 이미 종료되어 state를 정리했습니다: $pid"
    return
  fi

  if ! is_expected_application_process; then
    warn "PID가 기대한 EXP-001 application JVM과 일치하지 않아 signal을 보내지 않습니다: $pid"
    return
  fi

  if ! kill "$pid"; then
    warn "startup cleanup 정상 종료 signal 전송에 실패했습니다: $pid"
    return
  fi

  deadline=$((SECONDS + STOP_TIMEOUT_SECONDS))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      clear_application_state
      warn "startup 실패 후 application JVM을 정상 종료하고 state를 정리했습니다."
      return
    fi
    if ! is_expected_application_process; then
      warn "startup cleanup 대기 중 PID가 기대한 process와 달라져 강제 종료하지 않습니다: $pid"
      return
    fi
    sleep 1
  done

  if ! is_expected_application_process; then
    warn "startup cleanup 강제 종료 직전 PID가 기대한 process와 달라져 강제 종료하지 않습니다: $pid"
    return
  fi

  if kill -9 "$pid"; then
    clear_application_state
    warn "startup 실패 후 application JVM을 강제 종료하고 state를 정리했습니다."
  else
    warn "startup cleanup 강제 종료에 실패했습니다: $pid"
  fi
}

assert_official_settings() {
  [[ "$EXPECTED_INPUT_COUNT" == "50000" ]] || die "official EXPECTED_INPUT_COUNT는 정확히 50000이어야 합니다: $EXPECTED_INPUT_COUNT"
  [[ "$OFFICIAL_ROUNDS" == "6" ]] || die "official OFFICIAL_ROUNDS는 정확히 6이어야 합니다: $OFFICIAL_ROUNDS"
}
