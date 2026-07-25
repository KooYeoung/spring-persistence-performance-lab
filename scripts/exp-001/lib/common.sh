#!/usr/bin/env bash
set -Eeuo pipefail

EXP001_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
EXP001_ENV_FILE="$EXP001_SCRIPT_DIR/.env"

if [[ -f "$EXP001_ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$EXP001_ENV_FILE"
  set +a
fi

: "${PROJECT_ROOT:=../..}"
: "${BASE_URL:=http://localhost:8080}"
: "${DB_HOST:=localhost}"
: "${DB_PORT:=55432}"
: "${DB_NAME:=persistence_lab}"
: "${DB_USER:=lab_user}"
: "${DB_PASSWORD:=lab_password}"
: "${SPRING_PROFILE:=exp001}"
: "${EXPECTED_INPUT_COUNT:=50000}"
: "${OFFICIAL_ROUNDS:=6}"
: "${COOLDOWN_SECONDS:=10}"
: "${REQUEST_TIMEOUT_SECONDS:=600}"
: "${ALLOW_DESTRUCTIVE_RESET:=false}"
: "${RESULT_ROOT:=results/exp-001}"

PROJECT_ROOT_ABS="$(cd "$EXP001_SCRIPT_DIR/$PROJECT_ROOT" && pwd -P)"
RESULT_ROOT_ABS="$PROJECT_ROOT_ABS/$RESULT_ROOT"
EXP001_STATE_DIR="$EXP001_SCRIPT_DIR/.state"
EXP001_PID_FILE="$EXP001_STATE_DIR/app.pid"
EXP001_APP_METADATA_FILE="$EXP001_STATE_DIR/application.metadata"
EXP001_APP_LOG="$EXP001_STATE_DIR/application.log"

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

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "필수 command를 찾을 수 없습니다: $command_name"
}

ensure_directories() {
  mkdir -p "$EXP001_STATE_DIR" "$RESULT_ROOT_ABS"
}

assert_project_root() {
  [[ -f "$PROJECT_ROOT_ABS/settings.gradle" ]] || die "project root에서 settings.gradle을 찾을 수 없습니다: $PROJECT_ROOT_ABS"
  [[ -f "$PROJECT_ROOT_ABS/AGENTS.md" ]] || die "project root에서 AGENTS.md를 찾을 수 없습니다: $PROJECT_ROOT_ABS"
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
  PGPASSWORD="$DB_PASSWORD" psql \
    --host "$DB_HOST" \
    --port "$DB_PORT" \
    --username "$DB_USER" \
    --dbname "$DB_NAME" \
    --no-align \
    --tuples-only \
    --no-psqlrc \
    --set ON_ERROR_STOP=1 \
    --command "$sql" | tr -d '\r'
}

psql_exec() {
  local sql="$1"
  PGPASSWORD="$DB_PASSWORD" psql \
    --host "$DB_HOST" \
    --port "$DB_PORT" \
    --username "$DB_USER" \
    --dbname "$DB_NAME" \
    --no-psqlrc \
    --set ON_ERROR_STOP=1 \
    --command "$sql" >/dev/null
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

write_app_metadata() {
  local pid="$1"
  local boot_jar="$2"
  local profile="$3"

  {
    printf 'PID=%s\n' "$pid"
    printf 'BOOT_JAR=%s\n' "$boot_jar"
    printf 'BOOT_JAR_NAME=%s\n' "$(basename "$boot_jar")"
    printf 'SPRING_PROFILE=%s\n' "$profile"
  } >"$EXP001_APP_METADATA_FILE"
}

metadata_value() {
  local key="$1"
  local name
  local value

  [[ -f "$EXP001_APP_METADATA_FILE" ]] || return 1
  while IFS='=' read -r name value; do
    if [[ "$name" == "$key" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done <"$EXP001_APP_METADATA_FILE"
  return 1
}

clear_app_state() {
  rm -f "$EXP001_PID_FILE" "$EXP001_APP_METADATA_FILE"
}

jps_line_for_pid() {
  local pid="$1"
  jps -lmv | awk -v expected_pid="$pid" '$1 == expected_pid { print; found = 1 } END { if (!found) exit 1 }'
}

is_expected_app_process() {
  local pid="$1"
  local expected_jar="$2"
  local expected_jar_name="$3"
  local expected_profile="$4"
  local jps_line

  jps_line="$(jps_line_for_pid "$pid")" || return 1
  [[ "$jps_line" == *"$expected_jar"* || "$jps_line" == *"$expected_jar_name"* ]] || return 1
  [[ "$jps_line" == *"--spring.profiles.active=$expected_profile"* ]] || return 1
}

call_benchmark_endpoint() {
  local path="$1"
  local output_file="$2"
  local count="$3"
  local url="$BASE_URL/internal/exp-001/$path"

  curl \
    --silent \
    --show-error \
    --fail \
    --max-time "$REQUEST_TIMEOUT_SECONDS" \
    --header "Content-Type: application/json" \
    --data "{\"count\":$count}" \
    --output "$output_file" \
    "$url"
}

jq_raw() {
  local expression="$1"
  local file="$2"
  jq -r "$expression" "$file"
}

verify_response() {
  local expected_path="$1"
  local file="$2"
  local expected_count="${3:-$EXPECTED_INPUT_COUNT}"

  [[ "$(jq_raw '.path' "$file")" == "$expected_path" ]] || die "응답 path가 일치하지 않습니다: $file"
  [[ "$(jq_raw '.inputCount' "$file")" == "$expected_count" ]] || die "inputCount가 일치하지 않습니다: $file"
  [[ "$(jq_raw '.savedCount' "$file")" == "$expected_count" ]] || die "savedCount가 일치하지 않습니다: $file"
  jq -e '.elapsedNanos > 0' "$file" >/dev/null || die "elapsedNanos가 양수가 아닙니다: $file"
  jq -e '.valid == true' "$file" >/dev/null || die "valid=true가 아닙니다: $file"
  [[ "$(jq_raw '.rowCount' "$file")" == "$expected_count" ]] || die "rowCount가 일치하지 않습니다: $file"
  [[ "$(jq_raw '.missingKeyCount' "$file")" == "0" ]] || die "missingKeyCount가 0이 아닙니다: $file"
  [[ "$(jq_raw '.unexpectedKeyCount' "$file")" == "0" ]] || die "unexpectedKeyCount가 0이 아닙니다: $file"
  [[ "$(jq_raw '.duplicateKeyCount' "$file")" == "0" ]] || die "duplicateKeyCount가 0이 아닙니다: $file"
  jq -e '(.expectedChecksum | type == "string") and (.expectedChecksum | test("^[0-9a-f]{64}$"))' "$file" >/dev/null \
    || die "expectedChecksum이 lowercase SHA-256 64자리 문자열이 아닙니다: $file"
  jq -e '(.actualChecksum | type == "string") and (.actualChecksum | test("^[0-9a-f]{64}$"))' "$file" >/dev/null \
    || die "actualChecksum이 lowercase SHA-256 64자리 문자열이 아닙니다: $file"
  jq -e '.expectedChecksum == .actualChecksum' "$file" >/dev/null \
    || die "checksum이 일치하지 않습니다: $file"
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
  printf '%s-%s\n' "$(date -u +"%Y%m%dT%H%M%S%3NZ")" "$(short_git_sha)"
}
