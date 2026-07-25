#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

main() {
  require_command java
  require_command curl
  require_command psql
  require_command jq
  require_command awk
  assert_project_root
  ensure_directories

  log "project root: $PROJECT_ROOT_ABS"
  log "result root: $RESULT_ROOT_ABS"
  log "Java version:"
  java -version

  require_app_endpoint_registered
  log "application reachable: $BASE_URL"

  require_db_safety_gate
  log "PostgreSQL configured identity와 actual identity를 확인했습니다."
  log "official timing 중 debugger, SQL logging, Hibernate statistics, profiler는 OFF 상태로 운영하세요."
}

main "$@"
