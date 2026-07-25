#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CURRENT_TEMP_FILE=""

cleanup_current_temp_file() {
  if [[ "$CURRENT_TEMP_FILE" != "" ]]; then
    rm -f -- "$CURRENT_TEMP_FILE"
  fi
}

trap cleanup_current_temp_file EXIT

run_one() {
  local path="$1"
  local output_file="$2"
  local label="$3"
  local temp_file="${output_file}.tmp.$$"

  [[ ! -e "$output_file" ]] || die "final output file이 이미 존재합니다: $output_file"
  rm -f -- "$temp_file"
  CURRENT_TEMP_FILE="$temp_file"

  require_db_safety_gate
  reset_benchmark_table
  log "$label: $path endpoint 호출"

  if ! call_benchmark_endpoint "$path" "$temp_file" "$EXPECTED_INPUT_COUNT"; then
    rm -f -- "$temp_file"
    CURRENT_TEMP_FILE=""
    die "HTTP 호출 실패로 결과를 final path에 반영하지 않았습니다: $output_file"
  fi

  if ! ( verify_response "$path" "$temp_file" "$EXPECTED_INPUT_COUNT" ); then
    rm -f -- "$temp_file"
    CURRENT_TEMP_FILE=""
    die "response 검증 실패로 결과를 final path에 반영하지 않았습니다: $output_file"
  fi

  if ! mv -- "$temp_file" "$output_file"; then
    rm -f -- "$temp_file"
    CURRENT_TEMP_FILE=""
    die "검증된 temporary JSON을 final path로 이동하지 못했습니다: $output_file"
  fi
  CURRENT_TEMP_FILE=""

  cooldown "$COOLDOWN_SECONDS"
}

main() {
  require_command git
  require_command curl
  require_command psql
  require_command jq
  require_command awk
  assert_project_root
  ensure_directories
  require_app_endpoint_registered

  local run_id
  run_id="$(new_run_id)"
  local run_dir="$RESULT_ROOT_ABS/$run_id"
  local warmup_dir="$run_dir/warmup"
  local official_dir="$run_dir/official"
  mkdir -p "$warmup_dir" "$official_dir"

  log "EXP-001 run ID: $run_id"
  log "warm-up 시작"
  run_one "jpa" "$warmup_dir/01-jpa-warmup.json" "warm-up JPA"
  run_one "jdbc" "$warmup_dir/02-jdbc-warmup.json" "warm-up JDBC"

  log "official rounds 시작"
  local round
  for ((round = 1; round <= OFFICIAL_ROUNDS; round++)); do
    if (( round % 2 == 1 )); then
      run_one "jpa" "$official_dir/round-$(printf '%02d' "$round")-01-jpa.json" "round $round position 1"
      run_one "jdbc" "$official_dir/round-$(printf '%02d' "$round")-02-jdbc.json" "round $round position 2"
    else
      run_one "jdbc" "$official_dir/round-$(printf '%02d' "$round")-01-jdbc.json" "round $round position 1"
      run_one "jpa" "$official_dir/round-$(printf '%02d' "$round")-02-jpa.json" "round $round position 2"
    fi
  done

  log "official JSON 저장 완료: $official_dir"
}

main "$@"
