#!/usr/bin/env bash
set -Eeuo pipefail

ASPROF_HOME="${EXP001_ASPROF_HOME:-/opt/async-profiler}"
ASPROF_BIN="$ASPROF_HOME/bin/asprof"
JFRCONV_BIN="$ASPROF_HOME/bin/jfrconv"
ASPROF_LIB="$ASPROF_HOME/lib/libasyncProfiler.so"
APP_JAR="${EXP001_APP_JAR:-/app/app.jar}"
APP_PROFILE="${SPRING_PROFILES_ACTIVE:-exp001}"
APP_URL="${EXP001_APP_URL:-http://127.0.0.1:8080}"
ARTIFACT_ROOT="${EXP001_ARTIFACT_ROOT:-/artifacts/exp-001/profiling}"
DEFAULT_COUNT="${EXP001_ROWS_PER_INVOCATION:-50000}"
PROC_ROOT="${EXP001_PROC_ROOT:-/proc}"
JCMD_LIST_FILE="${EXP001_JCMD_LIST_FILE:-}"

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >&2
  exit 1
}

show_help() {
  cat <<'EOF'
EXP-001 async-profiler container harness

Actions:
  run-app       run the EXP-001 Spring Boot application.
  require-tool  verify the mounted async-profiler tool.
  smoke         verify tiny cpu/ctimer/alloc profiler sessions.
  call          call one jpa/jdbc endpoint without profiler.
  record-chunk  run one profiler start/endpoint/stop/convert chunk.
EOF
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || die "Required file is missing: $file"
}

require_executable() {
  local file="$1"
  [[ -x "$file" ]] || die "Executable file is missing: $file"
}

require_tool() {
  require_executable "$ASPROF_BIN"
  require_executable "$JFRCONV_BIN"
  require_file "$ASPROF_LIB"

  local version
  version="$("$ASPROF_BIN" --version 2>&1 || true)"
  printf '%s\n' "$version" | grep -F 'async-profiler 4.5' >/dev/null \
    || die "async-profiler version does not match the lock"
  log "async-profiler 4.5 verified"
}

safe_name() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._=-]+$ ]] || die "Unsafe artifact name value"
}

validate_basename() {
  local value="$1"
  [[ -n "$value" ]] || die "Empty basename is not allowed"
  [[ "$value" != *'/'* && "$value" != *'\'* && "$value" != *'..'* && ! "$value" =~ ^[A-Za-z]: ]] \
    || die "Path traversal in basename is not allowed"
}

validate_output_path() {
  local output="$1"
  [[ -n "$output" ]] || die "output path is required"
  case "$output" in
    "$ARTIFACT_ROOT"/*) ;;
    *) die "output path must stay under artifact root" ;;
  esac
  validate_basename "$(basename "$output")"
  local parent
  parent="$(dirname "$output")"
  ensure_dir "$parent"
  local parent_physical
  local root_physical
  parent_physical="$(cd "$parent" && pwd -P)"
  root_physical="$(cd "$ARTIFACT_ROOT" && pwd -P)"
  case "$parent_physical" in
    "$root_physical"|"$root_physical"/*) ;;
    *) die "output path escapes artifact root" ;;
  esac
}

ensure_dir() {
  local dir="$1"
  mkdir -p "$dir"
  [[ -d "$dir" ]] || die "Unable to create directory"
}

promote_no_clobber() {
  local temp="$1"
  local final="$2"
  [[ -f "$temp" ]] || die "Temporary file is missing"
  [[ ! -e "$final" ]] || die "Final file already exists"
  mv "$temp" "$final"
}

current_uid() {
  id -u
}

proc_cmdline() {
  local pid="$1"
  tr '\0' ' ' <"$PROC_ROOT/$pid/cmdline" 2>/dev/null | sed 's/[[:space:]]*$//'
}

proc_environ() {
  local pid="$1"
  tr '\0' '\n' <"$PROC_ROOT/$pid/environ" 2>/dev/null
}

proc_uid() {
  local pid="$1"
  awk '/^Uid:/ {print $2; exit}' "$PROC_ROOT/$pid/status" 2>/dev/null
}

proc_start_identity() {
  local pid="$1"
  awk '{print $22}' "$PROC_ROOT/$pid/stat" 2>/dev/null
}

candidate_matches_target() {
  local pid="$1"
  [[ -r "$PROC_ROOT/$pid/cmdline" && -r "$PROC_ROOT/$pid/environ" && -r "$PROC_ROOT/$pid/status" && -r "$PROC_ROOT/$pid/stat" ]] || return 1

  local cmdline
  cmdline="$(proc_cmdline "$pid")" || return 1
  case "$cmdline" in
    *" -jar $APP_JAR "*|*" -jar $APP_JAR"|*" $APP_JAR "*|*"$APP_JAR") ;;
    *) return 1 ;;
  esac
  case "$cmdline" in
    *"--spring.profiles.active=$APP_PROFILE"*) ;;
    *)
      proc_environ "$pid" | grep -Fx "SPRING_PROFILES_ACTIVE=$APP_PROFILE" >/dev/null || return 1
      ;;
  esac

  local uid
  uid="$(proc_uid "$pid")" || return 1
  [[ "$uid" == "$(current_uid)" ]] || return 1
  [[ -n "$(proc_start_identity "$pid")" ]] || return 1
}

find_application_pid() {
  local matches=""
  local pid
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if candidate_matches_target "$pid"; then
      matches="${matches}${pid}
"
    fi
  done <<EOF
$(jcmd_list | awk '$1 ~ /^[0-9]+$/ {print $1}')
EOF

  local count
  count="$(printf '%s' "$matches" | awk 'NF > 0 {c++} END {print c+0}')"
  [[ "$count" == "1" ]] || die "Target JVM candidate count is not exactly one"
  printf '%s' "$matches" | awk 'NF > 0 {print; exit}'
}

jcmd_list() {
  if [[ -n "$JCMD_LIST_FILE" ]]; then
    cat "$JCMD_LIST_FILE"
  else
    jcmd -l
  fi
}

verify_jvm_identity() {
  local pid="$1"
  local expected_start="$2"
  candidate_matches_target "$pid" || die "Target JVM identity no longer matches"
  [[ "$(proc_start_identity "$pid")" == "$expected_start" ]] || die "Target JVM start identity changed"
}

run_app() {
  exec java \
    -jar "$APP_JAR" \
    "--spring.profiles.active=${SPRING_PROFILES_ACTIVE:-exp001}"
}

validate_strategy() {
  case "$1" in
    jpa|jdbc) ;;
    *) die "Unsupported strategy" ;;
  esac
}

validate_event() {
  case "$1" in
    cpu|ctimer|alloc) ;;
    *) die "Unsupported profiler event" ;;
  esac
}

validate_cpu_engine() {
  case "$1" in
    cpu|ctimer) ;;
    *) die "Unsupported CPU engine" ;;
  esac
}

expected_repetitions() {
  local profile_id="$1"
  case "$profile_id" in
    cpu-jpa) printf '1\n' ;;
    cpu-jdbc) printf '25\n' ;;
    alloc-jdbc) printf '5\n' ;;
    alloc-jpa) printf '1\n' ;;
    *) die "Unsupported profile id" ;;
  esac
}

validate_profile_inputs() {
  local profile_id="$1"
  local event="$2"
  local cpu_engine="$3"
  local strategy="$4"
  local interval="$5"
  local chunk_index="$6"
  local count="$7"

  safe_name "$profile_id"
  validate_event "$event"
  validate_cpu_engine "$cpu_engine"
  validate_strategy "$strategy"
  [[ "$chunk_index" =~ ^[1-9][0-9]*$ ]] || die "Chunk index must be positive"
  [[ "$count" == "50000" ]] || die "EXP-001 profile chunks require exactly 50000 rows"

  local expected
  expected="$(expected_repetitions "$profile_id")"
  [[ "$chunk_index" -le "$expected" ]] || die "Chunk index exceeds configured repetitions"

  case "$profile_id:$event:$strategy:$interval" in
    cpu-jpa:cpu:jpa:10ms|cpu-jpa:ctimer:jpa:10ms) ;;
    cpu-jdbc:cpu:jdbc:10ms|cpu-jdbc:ctimer:jdbc:10ms) ;;
    alloc-jdbc:alloc:jdbc:512k) ;;
    alloc-jpa:alloc:jpa:512k) ;;
    *) die "Profile input combination does not match profile-config.json" ;;
  esac

  if [[ "$event" == "cpu" || "$event" == "ctimer" ]]; then
    [[ "$event" == "$cpu_engine" ]] || die "CPU event must match selected CPU engine"
  else
    [[ "$cpu_engine" == "cpu" || "$cpu_engine" == "ctimer" ]] || die "Selected CPU engine is required for allocation chunks"
  fi
}

endpoint_url() {
  local strategy="$1"
  validate_strategy "$strategy"
  printf '%s/internal/exp-001/%s\n' "$APP_URL" "$strategy"
}

call_endpoint() {
  local strategy="${EXP001_STRATEGY:-${1:-}}"
  local count="${EXP001_COUNT:-$DEFAULT_COUNT}"
  local output="${EXP001_RESPONSE_OUTPUT:-${2:-}}"
  validate_strategy "$strategy"
  [[ "$count" =~ ^[1-9][0-9]*$ ]] || die "count must be positive"
  [[ "$count" -le 50000 ]] || die "count must not exceed 50000"
  [[ -n "$output" ]] || die "response output path is required"
  validate_output_path "$output"

  local temp="${output}.tmp.$$"
  rm -f "$temp"
  curl --fail --show-error --silent \
    --request POST \
    --header 'Content-Type: application/json' \
    --data "{\"count\":$count}" \
    "$(endpoint_url "$strategy")" >"$temp"
  grep -F '"valid":true' "$temp" >/dev/null || {
    rm -f "$temp"
    die "endpoint response is not valid"
  }
  promote_no_clobber "$temp" "$output"
}

asprof_start_maybe() {
  local event="$1"
  local interval="$2"
  local pid="$3"
  local stderr_file="$4"

  case "$event" in
    cpu|ctimer)
      "$ASPROF_BIN" start -e "$event" -i "$interval" "$pid" >"$stderr_file.stdout" 2>"$stderr_file"
      ;;
    alloc)
      "$ASPROF_BIN" start -e alloc --alloc "$interval" "$pid" >"$stderr_file.stdout" 2>"$stderr_file"
      ;;
    *)
      return 2
      ;;
  esac
}

asprof_start() {
  asprof_start_maybe "$@" || die "async-profiler start failed"
}

asprof_stop_jfr() {
  local pid="$1"
  local output="$2"
  local stderr_file="$3"
  local temp="${output}.tmp.$$"
  rm -f "$temp"
  "$ASPROF_BIN" stop -o jfr -f "$temp" "$pid" >"$stderr_file.stdout" 2>"$stderr_file" \
    || die "async-profiler stop failed"
  [[ -s "$temp" ]] || die "JFR output is empty"
  promote_no_clobber "$temp" "$output"
}

convert_cpu_collapsed() {
  local jfr="$1"
  local output="$2"
  local temp="${output}.tmp.$$"
  rm -f "$temp"
  "$JFRCONV_BIN" --cpu --dot --norm -o collapsed "$jfr" "$temp"
  [[ -s "$temp" ]] || die "CPU collapsed output is empty"
  promote_no_clobber "$temp" "$output"
}

convert_alloc_collapsed() {
  local jfr="$1"
  local samples_output="$2"
  local bytes_output="$3"
  local samples_temp="${samples_output}.tmp.$$"
  local bytes_temp="${bytes_output}.tmp.$$"
  rm -f "$samples_temp" "$bytes_temp"
  "$JFRCONV_BIN" --alloc --dot --norm -o collapsed "$jfr" "$samples_temp"
  "$JFRCONV_BIN" --alloc --total --dot --norm -o collapsed "$jfr" "$bytes_temp"
  [[ -s "$samples_temp" ]] || die "allocation sample collapsed output is empty"
  [[ -s "$bytes_temp" ]] || die "allocation byte collapsed output is empty"
  promote_no_clobber "$samples_temp" "$samples_output"
  promote_no_clobber "$bytes_temp" "$bytes_output"
}

record_chunk() {
  require_tool

  local profile_run_id="${EXP001_PROFILE_RUN_ID:-}"
  local profile_id="${EXP001_PROFILE_ID:-}"
  local event="${EXP001_EVENT:-}"
  local cpu_engine="${EXP001_CPU_ENGINE:-}"
  local strategy="${EXP001_STRATEGY:-}"
  local interval="${EXP001_INTERVAL:-}"
  local chunk_index="${EXP001_CHUNK_INDEX:-}"
  local count="${EXP001_COUNT:-$DEFAULT_COUNT}"

  [[ -n "$profile_run_id" ]] || die "EXP001_PROFILE_RUN_ID is required"
  [[ -n "$profile_id" ]] || die "EXP001_PROFILE_ID is required"
  [[ -n "$event" ]] || die "EXP001_EVENT is required"
  [[ -n "$cpu_engine" ]] || die "EXP001_CPU_ENGINE is required"
  [[ -n "$strategy" ]] || die "EXP001_STRATEGY is required"
  [[ -n "$interval" ]] || die "EXP001_INTERVAL is required"
  safe_name "$profile_run_id"
  validate_profile_inputs "$profile_id" "$event" "$cpu_engine" "$strategy" "$interval" "$chunk_index" "$count"

  local pid
  pid="$(find_application_pid)"
  local start_identity
  start_identity="$(proc_start_identity "$pid")" || die "Unable to read target JVM start identity"
  verify_jvm_identity "$pid" "$start_identity"

  local profile_dir="$ARTIFACT_ROOT/$profile_run_id/raw/$profile_id"
  ensure_dir "$profile_dir"
  local profile_dir_physical
  profile_dir_physical="$(cd "$profile_dir" && pwd -P)"
  local artifact_root_physical
  artifact_root_physical="$(cd "$ARTIFACT_ROOT" && pwd -P)"
  case "$profile_dir_physical" in
    "$artifact_root_physical"/*) ;;
    *) die "Profile output path escapes artifact root" ;;
  esac

  local chunk_text
  chunk_text="$(printf '%03d' "$chunk_index")"
  validate_basename "${chunk_text}-${strategy}-${event}"
  local prefix="$profile_dir/${chunk_text}-${strategy}-${event}"
  local response="$prefix.response.raw"
  local jfr="$prefix.jfr"
  local start_log="$prefix.asprof-start.log"
  local stop_log="$prefix.asprof-stop.log"

  log "profile chunk start: profile=$profile_id strategy=$strategy event=$event chunk=$chunk_text"
  verify_jvm_identity "$pid" "$start_identity"
  asprof_start "$event" "$interval" "$pid" "$start_log"
  call_endpoint "$strategy" "$count" "$response" || {
    "$ASPROF_BIN" stop "$pid" >/dev/null 2>&1 || true
    die "endpoint call failed inside profile window"
  }
  verify_jvm_identity "$pid" "$start_identity"
  asprof_stop_jfr "$pid" "$jfr" "$stop_log"

  if [[ "$event" == "alloc" ]]; then
    convert_alloc_collapsed "$jfr" "$prefix.alloc-samples.collapsed" "$prefix.alloc-bytes.collapsed"
  else
    convert_cpu_collapsed "$jfr" "$prefix.cpu.collapsed"
  fi

  log "profile chunk complete: profile=$profile_id strategy=$strategy event=$event chunk=$chunk_text"
}

smoke_one_event() {
  local event="$1"
  local interval="$2"
  local pid="$3"
  local smoke_dir="$4"
  local jfr="$smoke_dir/${event}.jfr"
  local start_log="$smoke_dir/${event}.asprof-start.log"
  local stop_log="$smoke_dir/${event}.asprof-stop.log"

  if ! asprof_start_maybe "$event" "$interval" "$pid" "$start_log"; then
    return 1
  fi
  sleep 2
  if ! asprof_stop_jfr "$pid" "$jfr" "$stop_log"; then
    return 1
  fi
  if [[ "$event" == "alloc" ]]; then
    convert_alloc_collapsed "$jfr" "$smoke_dir/${event}.alloc-samples.collapsed" "$smoke_dir/${event}.alloc-bytes.collapsed" || return 1
  else
    convert_cpu_collapsed "$jfr" "$smoke_dir/${event}.cpu.collapsed" || return 1
  fi
}

smoke() {
  require_tool
  local pid
  pid="$(find_application_pid)"
  local start_identity
  start_identity="$(proc_start_identity "$pid")" || die "Unable to read target JVM start identity"
  verify_jvm_identity "$pid" "$start_identity"

  local smoke_id
  smoke_id="${EXP001_SMOKE_ID:-smoke-$(date -u '+%Y%m%dT%H%M%SZ')}"
  safe_name "$smoke_id"
  local smoke_dir="$ARTIFACT_ROOT/$smoke_id/raw/smoke"
  ensure_dir "$smoke_dir"

  local selected_cpu_engine=""
  log "smoke attach start: event=cpu"
  if smoke_one_event cpu 10ms "$pid" "$smoke_dir"; then
    selected_cpu_engine="cpu"
  else
    log "cpu smoke failed; trying ctimer fallback"
    "$ASPROF_BIN" stop "$pid" >/dev/null 2>&1 || true
    smoke_one_event ctimer 10ms "$pid" "$smoke_dir" || die "ctimer smoke failed"
    selected_cpu_engine="ctimer"
  fi
  if [[ "$selected_cpu_engine" == "cpu" ]]; then
    smoke_one_event ctimer 10ms "$pid" "$smoke_dir" || die "ctimer fallback smoke failed"
  fi
  smoke_one_event alloc 512k "$pid" "$smoke_dir" || die "allocation smoke failed"

  verify_jvm_identity "$pid" "$start_identity"
  printf '{"smokeSuccess":true,"selectedCpuEngine":"%s","events":["cpu","ctimer","alloc"]}\n' "$selected_cpu_engine" >"$smoke_dir/smoke-ready.json"
  log "smoke complete"
}

action="${1:-help}"
shift || true

case "$action" in
  run-app) run_app "$@" ;;
  require-tool) require_tool ;;
  smoke) smoke ;;
  call) call_endpoint "$@" ;;
  record-chunk) record_chunk ;;
  fixture-find-pid) find_application_pid >/dev/null ;;
  fixture-verify-identity) verify_jvm_identity "$1" "$2" ;;
  fixture-validate-inputs) validate_profile_inputs "$@" ;;
  fixture-validate-output) validate_output_path "$1" ;;
  help|-h|--help) show_help ;;
  *) show_help; die "Unknown action: $action" ;;
esac
