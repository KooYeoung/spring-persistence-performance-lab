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
EXP001_JDK_LOCK_FILE="$EXP001_ROOT/tools/jdk.lock"
EXP001_VALIDATE_RESPONSE_FILTER="$EXP001_ROOT/shared/validate-response.jq"
EXP001_FORMAT_RESPONSE_FILTER="$EXP001_ROOT/shared/format-response.jq"
EXP001_SUMMARY_FILTER="$EXP001_ROOT/shared/summary.jq"
EXP001_POSTGRES_SERVICE="persistence-lab-postgres"
EXP001_PLATFORM_NAME="macos"

PROJECT_ROOT="../.."
BASE_URL="http://localhost:8080"
SERVER_PORT=""
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
LOCKED_JDK_HOME=""
LOCKED_JDK_JAVA=""
LOCKED_JDK_JAVAC=""

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
    SERVER_PORT) SERVER_PORT="$value" ;;
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
  docker info >/dev/null 2>&1 || die "Docker Engine에 연결할 수 없습니다. Docker Desktop을 실행하세요. 권한 또는 Engine 연결 문제일 수 있습니다."
  docker compose version >/dev/null 2>&1 || die "docker compose를 사용할 수 없습니다. Docker Desktop의 Compose plugin을 확인하세요."

  local compose_file="$PROJECT_ROOT_ABS/docker-compose.yml"
  local services
  services="$(docker compose -f "$compose_file" config --services 2>/dev/null)" \
    || die "Docker Compose service 목록을 확인할 수 없습니다: $compose_file"
  printf '%s\n' "$services" | grep -Fx "$EXP001_POSTGRES_SERVICE" >/dev/null \
    || die "Docker Compose PostgreSQL service를 확인할 수 없습니다: $EXP001_POSTGRES_SERVICE"

  local container_id
  container_id="$(docker compose -f "$compose_file" ps -q "$EXP001_POSTGRES_SERVICE" 2>/dev/null | sed -n '1p')" \
    || die "Docker Compose PostgreSQL service 상태를 확인할 수 없습니다: $EXP001_POSTGRES_SERVICE"
  [[ "$container_id" != "" ]] \
    || die "Docker Compose PostgreSQL service가 실행 중이 아닙니다. 먼저 docker compose up -d를 실행하세요: $EXP001_POSTGRES_SERVICE"

  local running
  running="$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null | sed -n '1p')" \
    || die "Docker Compose PostgreSQL container 상태를 확인할 수 없습니다: $EXP001_POSTGRES_SERVICE"
  [[ "$running" == "true" ]] \
    || die "Docker Compose PostgreSQL service가 running 상태가 아닙니다: $EXP001_POSTGRES_SERVICE"

  local health
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null | sed -n '1p')" \
    || die "Docker Compose PostgreSQL health를 확인할 수 없습니다: $EXP001_POSTGRES_SERVICE"
  [[ "$health" == "healthy" ]] \
    || die "Docker Compose PostgreSQL service health가 healthy가 아닙니다: $EXP001_POSTGRES_SERVICE ($health)"
}

ensure_directories() {
  mkdir -p "$EXP001_STATE_DIR" "$EXP001_TOOLS_DIR" "$RESULT_ROOT_ABS"
}

assert_project_root() {
  [[ -f "$PROJECT_ROOT_ABS/settings.gradle" ]] || die "project root에서 settings.gradle을 찾을 수 없습니다: $PROJECT_ROOT_ABS"
  [[ -f "$PROJECT_ROOT_ABS/AGENTS.md" ]] || die "project root에서 AGENTS.md를 찾을 수 없습니다: $PROJECT_ROOT_ABS"
}

configured_server_port() {
  if [[ "$SERVER_PORT" != "" ]]; then
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

lock_file_value() {
  local lock_file="$1"
  local expected_key="$2"
  local line
  local key
  local value

  [[ -f "$lock_file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ "$line" == "" || "${line#\#}" != "$line" ]] && continue
    [[ "$line" == *"="* ]] || die "KEY=VALUE 형식이 아닌 line입니다: $lock_file"
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    if [[ "$key" == "$expected_key" ]]; then
      printf '%s\n' "$value"
      return
    fi
  done <"$lock_file"

  return 1
}

lock_value() {
  local expected_key="$1"
  lock_file_value "$EXP001_JQ_LOCK_FILE" "$expected_key"
}

jdk_lock_value() {
  local expected_key="$1"
  lock_file_value "$EXP001_JDK_LOCK_FILE" "$expected_key"
}

require_jdk_lock_key() {
  local key="$1"
  jdk_lock_value "$key" >/dev/null || die "JDK lock에 필요한 key가 없습니다: $key"
}

jdk_platform_key() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64) printf 'macos_x64\n' ;;
    arm64) printf 'macos_arm64\n' ;;
    *) die "지원하지 않는 macOS JDK architecture입니다: $machine" ;;
  esac
}

jdk_platform_dir() {
  local platform_key="$1"
  case "$platform_key" in
    macos_x64) printf 'macos-x64\n' ;;
    macos_arm64) printf 'macos-arm64\n' ;;
    *) die "지원하지 않는 JDK platform key입니다: $platform_key" ;;
  esac
}

require_jdk_lock() {
  local platform_key="$1"
  local key

  for key in \
    vendor \
    java_version \
    asset_version \
    "${platform_key}_url" \
    "${platform_key}_sha256" \
    "${platform_key}_archive_type" \
    "${platform_key}_jdk_home"; do
    require_jdk_lock_key "$key"
  done

  [[ "$(jdk_lock_value vendor)" == "Amazon Corretto" ]] \
    || die "지원하지 않는 JDK vendor입니다: $(jdk_lock_value vendor)"
}

jdk_runtime_root() {
  local platform_key="$1"
  printf '%s\n' "$EXP001_TOOLS_DIR/jdk/$(jdk_platform_dir "$platform_key")"
}

jdk_runtime_home() {
  local platform_key="$1"
  printf '%s\n' "$(jdk_runtime_root "$platform_key")/$(jdk_lock_value "${platform_key}_jdk_home")"
}

jdk_top_level_name() {
  local platform_key="$1"
  local jdk_home
  jdk_home="$(jdk_lock_value "${platform_key}_jdk_home")"
  printf '%s\n' "${jdk_home%%/*}"
}

jdk_major_version() {
  local version="$1"
  printf '%s\n' "${version%%.*}"
}

jvm_version_number() {
  local version_text="$1"
  local version
  version="$(printf '%s\n' "$version_text" | sed -n 's/.*version "\([^"]*\)".*/\1/p' | sed -n '1p')"
  if [[ "$version" == "" ]]; then
    version="$(printf '%s\n' "$version_text" | sed -n 's/^javac \([^[:space:]]*\).*/\1/p' | sed -n '1p')"
  fi
  printf '%s\n' "$version"
}

jdk_release_value() {
  local release_file="$1"
  local key="$2"
  sed -n "s/^${key}=\"\\(.*\\)\"$/\\1/p" "$release_file" | sed -n '1p'
}

test_locked_jdk_home() {
  local candidate="$1"
  local java_version
  local asset_version
  local home
  local java_bin
  local javac_bin
  local release_file
  local java_text
  local javac_text
  local actual_java_version
  local actual_javac_version

  [[ "$candidate" != "" && -d "$candidate" ]] || return 1
  home="$(cd "$candidate" && pwd -P)" || return 1
  java_bin="$home/bin/java"
  javac_bin="$home/bin/javac"
  release_file="$home/release"
  [[ -x "$java_bin" && -x "$javac_bin" && -f "$release_file" ]] || return 1

  java_version="$(jdk_lock_value java_version)" || return 1
  asset_version="$(jdk_lock_value asset_version)" || return 1
  [[ "$(jdk_release_value "$release_file" IMPLEMENTOR)" == "Amazon.com Inc." ]] || return 1
  [[ "$(jdk_release_value "$release_file" IMPLEMENTOR_VERSION)" == "Corretto-$asset_version" ]] || return 1
  [[ "$(jdk_release_value "$release_file" JAVA_VERSION)" == "$java_version" ]] || return 1

  java_text="$("$java_bin" -version 2>&1)" || return 1
  javac_text="$("$javac_bin" -version 2>&1)" || return 1
  actual_java_version="$(jvm_version_number "$java_text")"
  actual_javac_version="$(jvm_version_number "$javac_text")"
  [[ "$actual_java_version" == "$java_version" ]] || return 1
  [[ "$actual_javac_version" == "$java_version" ]] || return 1
  [[ "$(jdk_major_version "$actual_java_version")" == "21" ]] || return 1
  [[ "$(jdk_major_version "$actual_javac_version")" == "21" ]] || return 1

  printf '%s\n' "$home"
}

set_locked_jdk() {
  local home="$1"
  LOCKED_JDK_HOME="$home"
  LOCKED_JDK_JAVA="$home/bin/java"
  LOCKED_JDK_JAVAC="$home/bin/javac"
}

cleanup_locked_jdk_install() {
  local archive="$1"
  local extract_dir="$2"
  local final_top_level="$3"
  local moved_final_top_level="$4"

  rm -f -- "$archive" >/dev/null 2>&1 || true
  rm -rf -- "$extract_dir" >/dev/null 2>&1 || true
  if [[ "$moved_final_top_level" -eq 1 ]]; then
    rm -rf -- "$final_top_level" >/dev/null 2>&1 || true
  fi
  return 0
}

find_local_locked_jdk() {
  local platform_key="$1"
  local java_version
  local candidate
  local candidate_homes=()
  local seen_homes=()
  local home
  local seen
  local duplicate
  local root

  java_version="$(jdk_lock_value java_version)" || return 1

  if [[ "${JAVA_HOME:-}" != "" ]]; then
    candidate_homes+=("$JAVA_HOME")
  fi

  if [[ -x /usr/libexec/java_home ]]; then
    while IFS= read -r candidate; do
      [[ "$candidate" != "" ]] && candidate_homes+=("$candidate")
    done < <(/usr/libexec/java_home -v "$java_version" 2>/dev/null || true)
    while IFS= read -r candidate; do
      [[ "$candidate" != "" ]] && candidate_homes+=("$candidate")
    done < <(/usr/libexec/java_home --verbose 2>&1 | sed -n 's/^.* \(\/.*\/Contents\/Home\)$/\1/p')
  fi

  for root in \
    /Library/Java/JavaVirtualMachines \
    "$HOME/Library/Java/JavaVirtualMachines" \
    "$HOME/.jdks"; do
    [[ -d "$root" ]] || continue
    for candidate in "$root"/*/Contents/Home "$root"/*; do
      [[ -d "$candidate" ]] && candidate_homes+=("$candidate")
    done
  done

  for candidate in "${candidate_homes[@]}"; do
    [[ -d "$candidate" ]] || continue
    home="$(cd "$candidate" && pwd -P)" || continue
    duplicate=0
    for seen in "${seen_homes[@]}"; do
      if [[ "$seen" == "$home" ]]; then
        duplicate=1
        break
      fi
    done
    [[ "$duplicate" -eq 0 ]] || continue
    seen_homes+=("$home")

    if test_locked_jdk_home "$home" >/dev/null; then
      printf '%s\n' "$home"
      return
    fi
  done

  return 1
}

install_locked_jdk() {
  local platform_key="$1"
  local archive_type
  local url
  local expected_sha
  local runtime_root
  local runtime_home
  local top_level_name
  local final_top_level
  local archive
  local extract_dir
  local source_top_level
  local expected_extracted_home
  local verified_home
  local actual_sha
  local moved_final_top_level=0

  archive_type="$(jdk_lock_value "${platform_key}_archive_type")"
  [[ "$archive_type" == "tar.gz" ]] || die "지원하지 않는 macOS JDK archive type입니다: $archive_type"

  require_command curl
  require_command shasum
  require_command tar

  url="$(jdk_lock_value "${platform_key}_url")"
  expected_sha="$(jdk_lock_value "${platform_key}_sha256")"
  runtime_root="$(jdk_runtime_root "$platform_key")"
  runtime_home="$(jdk_runtime_home "$platform_key")"
  top_level_name="$(jdk_top_level_name "$platform_key")"
  final_top_level="$runtime_root/$top_level_name"
  archive="$runtime_root/amazon-corretto-$(jdk_lock_value asset_version)-$platform_key.$archive_type.tmp.$$"
  extract_dir="$runtime_root/extract-$$"
  source_top_level="$extract_dir/$top_level_name"
  expected_extracted_home="$extract_dir/$(jdk_lock_value "${platform_key}_jdk_home")"

  mkdir -p "$runtime_root"
  if verified_home="$(test_locked_jdk_home "$runtime_home")"; then
    set_locked_jdk "$verified_home"
    log "cached locked JDK 확인 완료: $LOCKED_JDK_HOME"
    return
  fi
  [[ ! -e "$runtime_home" ]] || die "JDK final runtime directory가 이미 존재하지만 lock 조건과 일치하지 않습니다: $runtime_home"
  [[ ! -e "$final_top_level" ]] || die "JDK final runtime top-level directory가 이미 존재하지만 lock 조건과 일치하지 않습니다: $final_top_level"
  [[ ! -e "$archive" ]] || die "JDK 임시 archive 경로가 이미 존재합니다: $archive"
  [[ ! -e "$extract_dir" ]] || die "JDK 임시 extraction directory가 이미 존재합니다: $extract_dir"

  log "Amazon Corretto JDK $(jdk_lock_value java_version) 다운로드: $platform_key"
  if ! curl --fail --location --silent --show-error --output "$archive" "$url"; then
    cleanup_locked_jdk_install "$archive" "$extract_dir" "$final_top_level" "$moved_final_top_level"
    die "JDK archive 다운로드에 실패했습니다."
  fi

  if ! actual_sha="$(sha256_file "$archive")"; then
    cleanup_locked_jdk_install "$archive" "$extract_dir" "$final_top_level" "$moved_final_top_level"
    die "JDK archive SHA-256 계산에 실패했습니다."
  fi
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    cleanup_locked_jdk_install "$archive" "$extract_dir" "$final_top_level" "$moved_final_top_level"
    die "downloaded JDK checksum이 일치하지 않습니다. expected=$expected_sha actual=$actual_sha"
  fi

  if ! mkdir -p "$extract_dir"; then
    cleanup_locked_jdk_install "$archive" "$extract_dir" "$final_top_level" "$moved_final_top_level"
    die "JDK archive 압축 해제 임시 directory 생성에 실패했습니다: $extract_dir"
  fi
  if ! tar -xzf "$archive" -C "$extract_dir"; then
    cleanup_locked_jdk_install "$archive" "$extract_dir" "$final_top_level" "$moved_final_top_level"
    die "JDK archive 압축 해제에 실패했습니다."
  fi

  if [[ ! -e "$source_top_level" ]]; then
    cleanup_locked_jdk_install "$archive" "$extract_dir" "$final_top_level" "$moved_final_top_level"
    die "압축 해제된 JDK top-level directory를 찾을 수 없습니다: $source_top_level"
  fi
  if ! verified_home="$(test_locked_jdk_home "$expected_extracted_home")"; then
    cleanup_locked_jdk_install "$archive" "$extract_dir" "$final_top_level" "$moved_final_top_level"
    die "압축 해제된 JDK가 lock 조건과 일치하지 않습니다."
  fi

  if [[ -e "$runtime_home" ]]; then
    cleanup_locked_jdk_install "$archive" "$extract_dir" "$final_top_level" "$moved_final_top_level"
    die "JDK final runtime directory가 이미 존재합니다: $runtime_home"
  fi
  if [[ -e "$final_top_level" ]]; then
    cleanup_locked_jdk_install "$archive" "$extract_dir" "$final_top_level" "$moved_final_top_level"
    die "JDK final runtime top-level directory가 이미 존재합니다: $final_top_level"
  fi
  if ! mv -- "$source_top_level" "$final_top_level"; then
    cleanup_locked_jdk_install "$archive" "$extract_dir" "$final_top_level" "$moved_final_top_level"
    die "JDK final runtime top-level directory 이동에 실패했습니다: $final_top_level"
  fi
  moved_final_top_level=1

  if ! verified_home="$(test_locked_jdk_home "$runtime_home")"; then
    cleanup_locked_jdk_install "$archive" "$extract_dir" "$final_top_level" "$moved_final_top_level"
    die "이동된 JDK가 lock 조건과 일치하지 않습니다: $runtime_home"
  fi

  cleanup_locked_jdk_install "$archive" "$extract_dir" "$final_top_level" 0
  set_locked_jdk "$verified_home"
  log "locked JDK 준비 완료: $LOCKED_JDK_HOME"
}

resolve_locked_jdk() {
  local allow_download=0
  local platform_key
  local local_home
  local runtime_home
  local verified_home

  if [[ "${1:-}" == "--allow-download" ]]; then
    allow_download=1
  fi

  if [[ "$LOCKED_JDK_HOME" != "" ]]; then
    return
  fi

  platform_key="$(jdk_platform_key)"
  require_jdk_lock "$platform_key"

  if local_home="$(find_local_locked_jdk "$platform_key")"; then
    set_locked_jdk "$local_home"
    log "local locked JDK 확인 완료: $LOCKED_JDK_HOME"
    return
  fi

  runtime_home="$(jdk_runtime_home "$platform_key")"
  if verified_home="$(test_locked_jdk_home "$runtime_home")"; then
    set_locked_jdk "$verified_home"
    log "cached locked JDK 확인 완료: $LOCKED_JDK_HOME"
    return
  fi

  if [[ "$allow_download" -eq 1 ]]; then
    install_locked_jdk "$platform_key"
    return
  fi

  die "lock과 일치하는 Amazon Corretto JDK $(jdk_lock_value java_version)를 찾지 못했습니다. 먼저 prepare를 실행하세요."
}

assert_java21() {
  resolve_locked_jdk
}

run_with_locked_jdk() {
  JAVA_HOME="$LOCKED_JDK_HOME" PATH="$LOCKED_JDK_HOME/bin:$PATH" "$@"
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
  if command -v shasum >/dev/null 2>&1; then
    IFS=' ' read -r checksum ignored < <(shasum -a 256 "$file")
  elif command -v sha256sum >/dev/null 2>&1; then
    IFS=' ' read -r checksum ignored < <(sha256sum "$file")
  else
    die "SHA-256 command를 찾지 못했습니다: shasum 또는 sha256sum"
  fi
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

  if [[ "${EXP001_JQ_BIN_CACHE:-}" != "" ]]; then
    printf '%s\n' "$EXP001_JQ_BIN_CACHE"
    return
  fi

  if [[ "${EXP001_JQ_BIN_OVERRIDE:-}" != "" ]]; then
    target="$EXP001_JQ_BIN_OVERRIDE"
    [[ -f "$target" ]] || die "EXP001_JQ_BIN_OVERRIDE가 regular file이 아닙니다: $target"
    [[ -x "$target" ]] || die "EXP001_JQ_BIN_OVERRIDE가 executable이 아닙니다: $target"
    [[ "$("$target" --version 2>/dev/null)" == "jq-$(lock_value version)" ]] \
      || die "EXP001_JQ_BIN_OVERRIDE jq version이 lock과 일치하지 않습니다: $target"
    EXP001_JQ_BIN_CACHE="$target"
    printf '%s\n' "$target"
    return
  fi

  platform_key="$(jq_platform_key)"
  expected_sha="$(lock_value "${platform_key}_sha256")" || die "jq lock에서 SHA-256을 찾지 못했습니다: ${platform_key}_sha256"
  target="$(jq_path "$platform_key")"
  assert_jq_checksum "$target" "$expected_sha"
  EXP001_JQ_BIN_CACHE="$target"
  printf '%s\n' "$target"
}

assert_text_file_lf_utf8_no_bom_final_newline() {
  local file="$1"
  local size
  local first3
  local last1
  local last2
  local without_nul_size

  [[ -f "$file" ]] || {
    printf '검증할 파일이 없습니다: %s\n' "$file" >&2
    return 1
  }
  [[ -s "$file" ]] || {
    printf '파일이 비어 있습니다: %s\n' "$file" >&2
    return 1
  }

  first3="$(LC_ALL=C od -An -tx1 -N3 "$file" | tr -d ' \n')"
  [[ "$first3" != "efbbbf" ]] || {
    printf 'UTF-8 BOM이 포함되어 있습니다: %s\n' "$file" >&2
    return 1
  }

  if LC_ALL=C grep -q $'\r' "$file"; then
    printf 'CR byte가 포함되어 있습니다. LF만 허용합니다: %s\n' "$file" >&2
    return 1
  fi

  size="$(wc -c <"$file" | tr -d ' ')"
  without_nul_size="$(tr -d '\000' <"$file" | wc -c | tr -d ' ')"
  [[ "$size" == "$without_nul_size" ]] || {
    printf 'NUL byte가 포함되어 있습니다: %s\n' "$file" >&2
    return 1
  }

  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-8 -t UTF-8 "$file" >/dev/null || {
      printf 'UTF-8로 decode할 수 없는 byte가 있습니다: %s\n' "$file" >&2
      return 1
    }
  fi

  last1="$(tail -c 1 "$file" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
  [[ "$last1" == "0a" ]] || {
    printf '파일 마지막 byte가 LF가 아닙니다: %s\n' "$file" >&2
    return 1
  }

  if [[ "$size" -ge 2 ]]; then
    last2="$(tail -c 2 "$file" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
    [[ "$last2" != "0a0a" ]] || {
      printf '파일 끝에 final newline이 두 번 이상 있습니다: %s\n' "$file" >&2
      return 1
    }
  fi
}

jq_to_file() {
  local destination="$1"
  shift

  local parent
  local jq_bin
  local jq_args=()
  parent="$(dirname "$destination")"
  [[ -d "$parent" ]] || {
    printf 'destination parent directory가 없습니다: %s\n' "$destination" >&2
    return 1
  }
  [[ ! -e "$destination" ]] || {
    printf 'destination file이 이미 존재합니다: %s\n' "$destination" >&2
    return 1
  }

  jq_bin="$(require_jq)" || return 1
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) jq_args=(-b) ;;
  esac
  if ! "$jq_bin" "${jq_args[@]}" "$@" >"$destination"; then
    rm -f "$destination"
    return 1
  fi
}

promote_file_no_clobber() {
  local temp_path="$1"
  local final_path="$2"
  local temp_dir
  local final_dir

  [[ -f "$temp_path" && ! -L "$temp_path" ]] || {
    printf 'promotion source가 regular file이 아닙니다: %s\n' "$temp_path" >&2
    return 1
  }

  temp_dir="$(cd "$(dirname "$temp_path")" && pwd -P)" || {
    printf 'promotion source directory를 확인하지 못했습니다: %s\n' "$temp_path" >&2
    return 1
  }
  final_dir="$(cd "$(dirname "$final_path")" && pwd -P)" || {
    printf 'promotion destination directory를 확인하지 못했습니다: %s\n' "$final_path" >&2
    return 1
  }
  [[ "$temp_dir" == "$final_dir" ]] || {
    printf 'promotion source와 destination은 같은 directory여야 합니다: %s -> %s\n' "$temp_path" "$final_path" >&2
    return 1
  }
  [[ ! -e "$final_path" && ! -L "$final_path" ]] || {
    printf 'promotion destination이 이미 존재합니다: %s\n' "$final_path" >&2
    return 1
  }

  if ! ln "$temp_path" "$final_path"; then
    printf 'promotion hard link 생성에 실패했습니다: %s -> %s\n' "$temp_path" "$final_path" >&2
    return 1
  fi
  if ! rm -f "$temp_path"; then
    printf 'promotion temp cleanup에 실패했습니다. final은 유지합니다: %s\n' "$temp_path" >&2
    return 1
  fi
}

compare_formatted_response_semantics() {
  local raw_file="$1"
  local formatted_file="$2"
  local jq_bin

  jq_bin="$(require_jq)" || return 1
  "$jq_bin" -e -s '.[0] == (.[1] | del(.resultFormatVersion, .elapsedSeconds))' "$raw_file" "$formatted_file" >/dev/null
}

format_response() {
  local expected_path="$1"
  local raw_file="$2"
  local formatted_file="$3"
  local expected_count="$4"

  jq_to_file "$formatted_file" \
    --arg expectedPath "$expected_path" \
    --argjson expectedCount "$expected_count" \
    -f "$EXP001_FORMAT_RESPONSE_FILTER" \
    "$raw_file" || return 1

  verify_response "$expected_path" "$formatted_file" "$expected_count" "v2" || return 1
  assert_text_file_lf_utf8_no_bom_final_newline "$formatted_file" || return 1
  compare_formatted_response_semantics "$raw_file" "$formatted_file" || return 1
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

require_configured_db_identity() {
  case "$DB_HOST" in
    localhost|127.0.0.1) ;;
    *) die "DB_HOST가 허용된 local host가 아닙니다: $DB_HOST" ;;
  esac

  [[ "$DB_PORT" == "55432" ]] || die "DB_PORT가 55432가 아닙니다: $DB_PORT"
  [[ "$DB_NAME" == "persistence_lab" ]] || die "DB_NAME이 persistence_lab이 아닙니다: $DB_NAME"
  [[ "$DB_USER" == "lab_user" ]] || die "DB_USER가 lab_user가 아닙니다: $DB_USER"
}

require_destructive_reset_approved() {
  [[ "$ALLOW_DESTRUCTIVE_RESET" == "true" ]] || die "ALLOW_DESTRUCTIVE_RESET가 true가 아니므로 reset과 run을 중단합니다."
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

require_db_identity_gate() {
  require_configured_db_identity
  require_actual_db_gate
}

require_destructive_reset_gate() {
  require_destructive_reset_approved
  require_configured_db_identity
  require_actual_db_gate
}

reset_benchmark_table() {
  require_destructive_reset_gate
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
  local mode="${4:-artifact}"
  local jq_bin

  jq_bin="$(require_jq)"
  "$jq_bin" -e --arg mode "$mode" --arg expectedPath "$expected_path" --argjson expectedCount "$expected_count" -f "$EXP001_VALIDATE_RESPONSE_FILTER" "$file" >/dev/null
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
