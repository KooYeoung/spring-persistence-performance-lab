#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXP_ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
TEST_PROJECT_ROOT="$(cd "$EXP_ROOT/../.." && pwd -P)"
PROFILER_ROOT="$TEST_PROJECT_ROOT/scripts/exp-001/profiler"
PROFILER_FIXTURES_DIR="$TEST_PROJECT_ROOT/scripts/exp-001/tests/profiler/fixtures"
PROFILER_EXPECTED_DIR="$TEST_PROJECT_ROOT/scripts/exp-001/tests/profiler/expected"
AGGREGATE_FILTER="$PROFILER_ROOT/shared/aggregate-collapsed.jq"
VALIDATE_SUMMARY_FILTER="$PROFILER_ROOT/shared/validate-profile-summary.jq"
CONFIG_FILE="$PROFILER_ROOT/shared/profile-config.json"
OFFICIAL_MANIFEST_FILE="$PROFILER_ROOT/shared/official-result-manifest.json"
ASYNC_PROFILER_LOCK_RELATIVE="scripts/exp-001/tools/async-profiler.lock"
CONTAINER_RUNNER_RELATIVE="scripts/exp-001/profiler/container/exp001-profile.sh"
ASYNC_PROFILER_LOCK_FILE="$TEST_PROJECT_ROOT/$ASYNC_PROFILER_LOCK_RELATIVE"
DOCKER_DIR="$PROFILER_ROOT/docker"
CONTAINER_RUNNER="$TEST_PROJECT_ROOT/$CONTAINER_RUNNER_RELATIVE"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

assert_success() {
  "$@" >/dev/null 2>&1 || fail "expected success: $*"
}

assert_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "expected failure: $*"
  fi
}

configure_jq_override_for_git_bash() {
  local kernel
  local override
  kernel="$(uname -s)"
  case "$kernel" in
    MINGW*|MSYS*|CYGWIN*)
      override="$EXP_ROOT/.tools/windows-x64/jq.exe"
      if command -v cygpath >/dev/null 2>&1; then
        override="$(cygpath -u "$override")"
      fi
      [[ -f "$override" ]] || fail "Windows locked jq not found: $override"
      export EXP001_JQ_BIN_OVERRIDE="$override"
      ;;
  esac
}

configure_jq_override_for_git_bash

# shellcheck source=../macos/common.sh
source "$EXP_ROOT/macos/common.sh"
initialize_exp001

assert_bytes_equal() {
  local expected="$1"
  local actual="$2"
  cmp -s "$expected" "$actual" || fail "byte mismatch: expected=$expected actual=$actual"
}

lock_value_from_file() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1)}' "$ASYNC_PROFILER_LOCK_FILE"
}

read_locked_profiler_version() {
  local lock_file="$1"
  [[ -f "$lock_file" ]] || {
    printf 'async-profiler lock file is missing\n' >&2
    return 10
  }
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^version=/) {
        count++
        value = substr(line, 9)
        if (value == "") {
          empty = 1
        } else if (value !~ /^[0-9]+[.][0-9]+([.][0-9]+)?$/) {
          malformed = 1
        } else {
          parsed = value
        }
        next
      }
      if (line ~ /^[[:blank:]]+version=/ || line ~ /^version[[:blank:]]+=/) {
        malformed = 1
      }
    }
    END {
      if (count > 1) {
        print "duplicate lock version field" > "/dev/stderr"
        exit 11
      }
      if (malformed) {
        print "malformed lock version field" > "/dev/stderr"
        exit 12
      }
      if (count == 0) {
        print "missing lock version field" > "/dev/stderr"
        exit 13
      }
      if (empty) {
        print "empty lock version field" > "/dev/stderr"
        exit 14
      }
      print parsed
    }
  ' "$lock_file"
}

read_runtime_expected_profiler_version() {
  local production_script="$1"
  [[ -f "$production_script" ]] || {
    printf 'runtime profiler script is missing\n' >&2
    return 20
  }
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^ASPROF_EXPECTED_VERSION=/) {
        count++
        if (line !~ /^ASPROF_EXPECTED_VERSION=".*"$/) {
          malformed = 1
          next
        }
        value = line
        sub(/^ASPROF_EXPECTED_VERSION="/, "", value)
        sub(/"$/, "", value)
        if (value == "") {
          empty = 1
        } else if (value !~ /^[0-9]+[.][0-9]+([.][0-9]+)?$/) {
          malformed = 1
        } else {
          parsed = value
        }
        next
      }
      if (line ~ /^[[:blank:]]*ASPROF_EXPECTED_VERSION[[:blank:]]*=/) {
        malformed = 1
      }
    }
    END {
      if (count > 1) {
        print "duplicate runtime ASPROF_EXPECTED_VERSION assignment" > "/dev/stderr"
        exit 21
      }
      if (malformed) {
        print "malformed runtime ASPROF_EXPECTED_VERSION assignment" > "/dev/stderr"
        exit 22
      }
      if (count == 0) {
        print "missing runtime ASPROF_EXPECTED_VERSION assignment" > "/dev/stderr"
        exit 23
      }
      if (empty) {
        print "empty runtime ASPROF_EXPECTED_VERSION assignment" > "/dev/stderr"
        exit 24
      }
      print parsed
    }
  ' "$production_script"
}

assert_profiler_version_contract() {
  local lock_file="$1"
  local production_script="$2"
  local lock_version
  local runtime_version
  lock_version="$(read_locked_profiler_version "$lock_file")" || return 1
  runtime_version="$(read_runtime_expected_profiler_version "$production_script")" || return 1
  if [[ "$lock_version" != "$runtime_version" ]]; then
    printf 'async-profiler lock/runtime version drift: lock=%s runtime=%s\n' "$lock_version" "$runtime_version" >&2
    return 1
  fi
  printf 'async-profiler lock/runtime version contract passed: %s\n' "$lock_version"
}

assert_async_profiler_lock() {
  [[ "$(lock_value_from_file version)" == "4.5" ]] || fail "async-profiler version mismatch"
  [[ "$(lock_value_from_file tag)" == "v4.5" ]] || fail "async-profiler tag mismatch"
  [[ "$(lock_value_from_file platform)" == "linux-x64" ]] || fail "async-profiler platform mismatch"
  [[ "$(lock_value_from_file asset)" == "async-profiler-4.5-linux-x64.tar.gz" ]] || fail "async-profiler asset mismatch"
  [[ "$(lock_value_from_file sha256)" == "89546fbb9ee0fc5496c7edd4099b0709489bc78b0d8057ccbb4b801f6b032b62" ]] || fail "async-profiler sha mismatch"
  [[ "$(lock_value_from_file size)" == "447164" ]] || fail "async-profiler size mismatch"
  [[ "$(lock_value_from_file asprof)" == "bin/asprof" ]] || fail "asprof path mismatch"
  [[ "$(lock_value_from_file jfrconv)" == "bin/jfrconv" ]] || fail "jfrconv path mismatch"
  [[ "$(lock_value_from_file library)" == "lib/libasyncProfiler.so" ]] || fail "library path mismatch"
}

assert_profile_config() {
  "$JQ_BIN" -e '
    .profileConfigVersion == 1
    and .experiment == "EXP-001"
    and .rowsPerInvocation == 50000
    and .smoke.smokeProtocolVersion == "exp001-smoke-v1"
    and .smoke.readinessStatus == "READY"
    and .smoke.readinessPhase == "EXP001_SMOKE"
    and .smoke.responseMaxBytes == 4096
    and .smoke.cpuWorkload.version == "cpu-v1"
    and .smoke.cpuWorkload.successLowerBoundMillis == 2500
    and .smoke.cpuWorkload.minimumSamples == 50
    and .smoke.allocationWorkload.version == "allocation-v1"
    and .smoke.allocationWorkload.allocatedBytes == 67108864
    and .smoke.allocationWorkload.minimumSampledBytes == 4194304
    and (.profileOrder | length == 4)
    and all(.profiles[]; ((.event == "cpu" or .event == "ctimer" or .event == "alloc")
      and (.strategy == "jpa" or .strategy == "jdbc")
      and (.repetitions > 0)
      and (.minimumSamples > 0)
      and (.recommendedSamples >= .minimumSamples)))
    and ((.runtime.dockerSecurityLevels[] | select(.level == 0) | .capAdd | length) == 0)
    and ((.runtime.dockerSecurityLevels[] | select(.level == 0) | .securityOpt | length) == 0)
  ' "$CONFIG_FILE" >/dev/null || fail "profile-config.json validation failed"
}

assert_docker_policy() {
  local file
  for file in "$DOCKER_DIR/compose.yml" "$DOCKER_DIR/compose.seccomp.yml" "$DOCKER_DIR/compose.sys-admin.yml"; do
    ! grep -Eq '^[[:space:]]*privileged[[:space:]]*:[[:space:]]*true[[:space:]]*$' "$file" || fail "privileged true is forbidden: $file"
    ! grep -Eq '^[[:space:]]*pid[[:space:]]*:[[:space:]]*host[[:space:]]*$' "$file" || fail "host pid is forbidden: $file"
    ! grep -Eq '^[[:space:]]*container_name[[:space:]]*:' "$file" || fail "fixed container_name is forbidden: $file"
    ! grep -F '/var/run/docker.sock' "$file" >/dev/null || fail "Docker socket mount is forbidden: $file"
    ! grep -F 'SYS_PTRACE' "$file" >/dev/null || fail "SYS_PTRACE is not part of the default plan: $file"
  done
  ! grep -F 'SYS_ADMIN' "$DOCKER_DIR/compose.yml" >/dev/null || fail "Level 0 compose must not include SYS_ADMIN"
  ! grep -F 'seccomp=unconfined' "$DOCKER_DIR/compose.yml" >/dev/null || fail "Level 0 compose must not include seccomp override"
  grep -F '../../.tools/async-profiler/linux-x64/4.5/async-profiler-4.5-linux-x64:/opt/async-profiler:ro' "$DOCKER_DIR/compose.yml" >/dev/null || fail "async-profiler tool mount path mismatch"
  grep -F 'SYS_ADMIN' "$DOCKER_DIR/compose.sys-admin.yml" >/dev/null || fail "Level 2 override must include SYS_ADMIN"
}

assert_profile_summary_valid() {
  local file="$1"
  "$JQ_BIN" -e -f "$VALIDATE_SUMMARY_FILTER" "$file" >/dev/null || fail "profile summary validation failed: $file"
}

assert_profile_summary_invalid() {
  local file="$1"
  if "$JQ_BIN" -e -f "$VALIDATE_SUMMARY_FILTER" "$file" >/dev/null 2>/dev/null; then
    fail "profile summary unexpectedly passed: $file"
  fi
}

assert_official_result_manifest() {
  local result_root
  local expected_count
  local actual_count
  result_root="$TEST_PROJECT_ROOT/$("$JQ_BIN" -r '.officialResultPath' "$OFFICIAL_MANIFEST_FILE")"
  result_root="${result_root%$'\r'}"
  expected_count="$("$JQ_BIN" -r '.expectedFileCount' "$OFFICIAL_MANIFEST_FILE")"
  expected_count="${expected_count%$'\r'}"
  actual_count="$(find "$result_root" -type f | wc -l | tr -d ' ')"
  [[ "$actual_count" == "$expected_count" ]] || fail "official result file count changed: $actual_count"

  "$JQ_BIN" -r '.files[] | [.path, .sha256] | @tsv' "$OFFICIAL_MANIFEST_FILE" |
    while IFS=$'\t' read -r relative expected; do
      relative="${relative%$'\r'}"
      expected="${expected%$'\r'}"
      [[ -f "$TEST_PROJECT_ROOT/$relative" ]] || fail "official result file missing: $relative"
      actual="$(sha256_file "$TEST_PROJECT_ROOT/$relative")"
      [[ "$actual" == "$expected" ]] || fail "official result SHA changed: $relative"
    done
}

git_attr_value() {
  local path="$1"
  local attribute="$2"
  git -C "$TEST_PROJECT_ROOT" check-attr "$attribute" -- "$path" | sed 's/^.*: [^:]*: //'
}

assert_git_attr() {
  local path="$1"
  local attribute="$2"
  local expected="$3"
  local actual
  actual="$(git_attr_value "$path" "$attribute")"
  [[ "$actual" == "$expected" ]] || fail "git attr mismatch: path=$path attr=$attribute expected=$expected actual=$actual"
}

assert_git_ignored() {
  local path="$1"
  git -C "$TEST_PROJECT_ROOT" check-ignore -q -- "$path" || fail "path should be ignored: $path"
}

assert_git_not_ignored() {
  local path="$1"
  if git -C "$TEST_PROJECT_ROOT" check-ignore -q -- "$path"; then
    fail "path should not be ignored: $path"
  fi
}

write_aggregate_manifest() {
  local path="$1"
  cat >"$path" <<'JSON'
{
  "aggregationFormatVersion": 1,
  "profileId": "cpu-jpa",
  "event": "cpu",
  "cpuEngine": "cpu",
  "strategy": "jpa",
  "interval": "10ms",
  "counterKind": "cpuSamples",
  "repetitions": 2,
  "rowsPerInvocation": 50000,
  "totalRows": 100000,
  "expectedChunkCount": 2,
  "chunks": [
    {
      "sequence": 1,
      "filename": "001-jpa-cpu.collapsed",
      "event": "cpu",
      "strategy": "jpa",
      "counterKind": "cpuSamples",
      "rows": 50000,
      "workloadValid": true,
      "sourceArtifactSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "collapsedContent": "com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService.saveAll;org.hibernate.engine.spi.ActionQueue.executeActions 3\ncom.example.persistencebenchmark.persistence.jdbc.JdbcBatchBenchmarkRecordPersistenceService.saveAll;org.postgresql.core.v3.QueryExecutorImpl.execute 4\n"
    },
    {
      "sequence": 2,
      "filename": "002-jpa-cpu.collapsed",
      "event": "cpu",
      "strategy": "jpa",
      "counterKind": "cpuSamples",
      "rows": 50000,
      "workloadValid": true,
      "sourceArtifactSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "collapsedContent": "com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService.saveAll;org.hibernate.engine.spi.ActionQueue.executeActions 2\njava.lang.Thread.run 1\n"
    }
  ]
}
JSON
}

assert_aggregation_invalid() {
  local filter="$1"
  local name="$2"
  local path="$temp_root/$name.json"
  "$JQ_BIN" "$filter" "$aggregate_manifest" >"$path"
  if "$JQ_BIN" -e -f "$AGGREGATE_FILTER" "$path" >/dev/null 2>/dev/null; then
    fail "aggregation manifest unexpectedly passed: $name"
  fi
}

write_fake_proc() {
  local root="$1"
  local pid="$2"
  local uid="$3"
  local jar="${4:-/app/app.jar}"
  local profile="${5:-exp001}"
  local start="${6:-987654}"
  local dir="$root/$pid"
  mkdir -p "$dir"
  printf 'java -jar %s --spring.profiles.active=%s' "$jar" "$profile" >"$dir/cmdline"
  printf 'SPRING_PROFILES_ACTIVE=%s\n' "$profile" >"$dir/environ"
  printf 'Name:\tjava\nUid:\t%s\t%s\t%s\t%s\n' "$uid" "$uid" "$uid" "$uid" >"$dir/status"
  printf '123 (java) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 %s\n' "$start" >"$dir/stat"
}

write_json_fixture() {
  local path="$1"
  local text="$2"
  printf '%s\n' "$text" >"$path"
}

assert_response_fixture_failure() {
  local name="$1"
  local action="$2"
  local text="$3"
  local path="$temp_root/${name}.json"
  write_json_fixture "$path" "$text"
  assert_failure run_container_fixture '' '' "$action" "$path"
}

assert_response_fixture_success() {
  local name="$1"
  local action="$2"
  local text="$3"
  local path="$temp_root/${name}.json"
  write_json_fixture "$path" "$text"
  assert_success run_container_fixture '' '' "$action" "$path"
}

write_fake_container_tools() {
  local root="$1"
  mkdir -p "$root/bin" "$root/lib"
  : >"$root/lib/libasyncProfiler.so"
  cat >"$root/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf 'curl\n' >>"${EXP001_FAKE_CURL_LOG:?}"
body="${EXP001_FAKE_CURL_BODY:?}"
case "$url" in
  */internal/exp-001/smoke/ready) body="${EXP001_FAKE_CURL_READY_BODY:-$body}" ;;
  */internal/exp-001/smoke/cpu) body="${EXP001_FAKE_CURL_CPU_BODY:-$body}" ;;
  */internal/exp-001/smoke/allocation) body="${EXP001_FAKE_CURL_ALLOCATION_BODY:-$body}" ;;
esac
if [[ -n "$output" ]]; then
  cat "$body" >"$output"
else
  cat "$body"
fi
if [[ -n "${EXP001_FAKE_IDENTITY_AFTER_CURL:-}" ]]; then
  printf '123 (java) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 %s\n' "$EXP001_FAKE_IDENTITY_AFTER_CURL" >"${EXP001_FAKE_PROC_ROOT:?}/${EXP001_FAKE_PID:?}/stat"
fi
if [[ -n "$output" ]]; then
  printf '%s' "${EXP001_FAKE_CURL_STATUS:-200}"
fi
exit "${EXP001_FAKE_CURL_EXIT:-0}"
SH
  cat >"$root/bin/asprof" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${EXP001_FAKE_ASPROF_LOG:?}"
case "${1:-}" in
  --version)
    version_stdout="${EXP001_FAKE_ASPROF_VERSION_STDOUT-async-profiler 4.5\\n}"
    printf '%b' "$version_stdout"
    if [[ -n "${EXP001_FAKE_ASPROF_VERSION_STDERR+x}" ]]; then
      printf '%b' "$EXP001_FAKE_ASPROF_VERSION_STDERR" >&2
    fi
    exit "${EXP001_FAKE_ASPROF_VERSION_EXIT:-0}"
    ;;
  start)
    [[ "${EXP001_FAKE_ASPROF_START_FAIL:-0}" != "1" ]] || exit 7
    ;;
  stop)
    [[ "${EXP001_FAKE_ASPROF_STOP_FAIL:-0}" != "1" ]] || exit 8
    output=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f) output="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ -n "$output" ]]; then
      printf 'fake-jfr\n' >"$output"
    fi
    ;;
  *)
    exit 9
    ;;
esac
SH
  cat >"$root/bin/jfrconv" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${EXP001_FAKE_JFRCONV_LOG:?}"
[[ "${EXP001_FAKE_JFRCONV_FAIL:-0}" != "1" ]] || exit 6
output=""
for arg in "$@"; do
  output="$arg"
done
case " $* " in
  *" --total "*) printf 'com.example.Allocation 8388608\n' >"$output" ;;
  *" --alloc "*) printf 'com.example.Allocation 16\n' >"$output" ;;
  *) printf 'com.example.Cpu 100\n' >"$output" ;;
esac
SH
  cat >"$root/bin/java" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
SH
  cat >"$root/bin/jfr" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${EXP001_FAKE_JFR_LOG:?}"
[[ "${EXP001_FAKE_JFR_FAIL:-0}" != "1" ]] || exit 5
cat "${EXP001_FAKE_JFR_JSON:?}"
SH
  chmod +x "$root/bin/curl" "$root/bin/asprof" "$root/bin/jfrconv" "$root/bin/java" "$root/bin/jfr"
}

run_fake_smoke_event() {
  local proc_root="$1"
  local smoke_dir="$2"
  local body="$3"
  local engine_json="$4"
  shift 4
  env \
    EXP001_PROC_ROOT="$proc_root" \
    EXP001_ASPROF_HOME="$fake_tools" \
    EXP001_CURL_BIN="$fake_tools/bin/curl" \
    EXP001_JFR_BIN="$fake_tools/bin/jfr" \
    EXP001_FAKE_CURL_BODY="$body" \
    EXP001_FAKE_CURL_LOG="$fake_curl_log" \
    EXP001_FAKE_ASPROF_LOG="$fake_asprof_log" \
    EXP001_FAKE_JFRCONV_LOG="$fake_jfrconv_log" \
    EXP001_FAKE_JFR_LOG="$fake_jfr_log" \
    EXP001_FAKE_JFR_JSON="$engine_json" \
    SPRING_PROFILES_ACTIVE=exp001 \
    "$@" "$CONTAINER_RUNNER" fixture-smoke-one-event cpu 10ms 123 987654 "$smoke_dir" cpu >/dev/null 2>&1
}

run_fake_smoke() {
  local proc_root="$1"
  local jcmd_file="$2"
  local artifact_root="$3"
  local smoke_id="$4"
  local ready_body="$5"
  local cpu_body="$6"
  local allocation_body="$7"
  local engine_json="$8"
  env \
    EXP001_PROC_ROOT="$proc_root" \
    EXP001_JCMD_LIST_FILE="$jcmd_file" \
    EXP001_ARTIFACT_ROOT="$artifact_root" \
    EXP001_SMOKE_ID="$smoke_id" \
    EXP001_ASPROF_HOME="$fake_tools" \
    EXP001_CURL_BIN="$fake_tools/bin/curl" \
    EXP001_JFR_BIN="$fake_tools/bin/jfr" \
    EXP001_FAKE_CURL_BODY="$ready_body" \
    EXP001_FAKE_CURL_READY_BODY="$ready_body" \
    EXP001_FAKE_CURL_CPU_BODY="$cpu_body" \
    EXP001_FAKE_CURL_ALLOCATION_BODY="$allocation_body" \
    EXP001_FAKE_CURL_LOG="$fake_curl_log" \
    EXP001_FAKE_ASPROF_LOG="$fake_asprof_log" \
    EXP001_FAKE_JFRCONV_LOG="$fake_jfrconv_log" \
    EXP001_FAKE_JFR_LOG="$fake_jfr_log" \
    EXP001_FAKE_JFR_JSON="$engine_json" \
    SPRING_PROFILES_ACTIVE=exp001 \
    "$CONTAINER_RUNNER" smoke >/dev/null 2>&1
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  grep -F -- "$expected" "$file" >/dev/null || fail "expected file to contain '$expected': $file"
}

assert_file_not_contains() {
  local file="$1"
  local unexpected="$2"
  if [[ -f "$file" ]] && grep -F -- "$unexpected" "$file" >/dev/null; then
    fail "file should not contain '$unexpected': $file"
  fi
}

reset_fake_tool_logs() {
  : >"$fake_curl_log"
  : >"$fake_asprof_log"
  : >"$fake_jfrconv_log"
  : >"$fake_jfr_log"
}

run_container_fixture() {
  local proc_root="${1:-}"
  local jcmd_file="${2:-}"
  shift 2 || true
  if [[ -n "$proc_root" ]]; then
    EXP001_PROC_ROOT="$proc_root" EXP001_JCMD_LIST_FILE="$jcmd_file" SPRING_PROFILES_ACTIVE=exp001 "$CONTAINER_RUNNER" "$@" >/dev/null 2>&1
  else
    SPRING_PROFILES_ACTIVE=exp001 "$CONTAINER_RUNNER" "$@" >/dev/null 2>&1
  fi
}

run_require_tool_fixture() {
  local version_stdout="$1"
  local version_stderr="$2"
  local version_exit="$3"
  env \
    EXP001_ASPROF_HOME="$fake_tools" \
    EXP001_JFR_BIN="$fake_tools/bin/jfr" \
    EXP001_JAVA_BIN="$fake_tools/bin/java" \
    EXP001_FAKE_ASPROF_LOG="$fake_asprof_log" \
    EXP001_FAKE_ASPROF_VERSION_STDOUT="$version_stdout" \
    EXP001_FAKE_ASPROF_VERSION_STDERR="$version_stderr" \
    EXP001_FAKE_ASPROF_VERSION_EXIT="$version_exit" \
    SPRING_PROFILES_ACTIVE=exp001 \
    "$CONTAINER_RUNNER" require-tool >/dev/null 2>&1
}

write_profiler_version_contract_fixture() {
  local name="$1"
  local lock_text="$2"
  local runtime_text="$3"
  local case_dir="$temp_root/profiler-version-contract-$name"
  local lock_file="$case_dir/async-profiler.lock"
  local runtime_file="$case_dir/exp001-profile.sh"
  mkdir -p "$case_dir"
  printf '%b' "$lock_text" >"$lock_file"
  printf '%b' "$runtime_text" >"$runtime_file"
  PROFILER_VERSION_CONTRACT_LOCK_FILE="$lock_file"
  PROFILER_VERSION_CONTRACT_RUNTIME_FILE="$runtime_file"
}

assert_profiler_version_contract_fixture_success() {
  local name="$1"
  local lock_text="$2"
  local runtime_text="$3"
  write_profiler_version_contract_fixture "$name" "$lock_text" "$runtime_text"
  assert_success assert_profiler_version_contract \
    "$PROFILER_VERSION_CONTRACT_LOCK_FILE" \
    "$PROFILER_VERSION_CONTRACT_RUNTIME_FILE"
}

assert_profiler_version_contract_fixture_failure() {
  local name="$1"
  local lock_text="$2"
  local runtime_text="$3"
  write_profiler_version_contract_fixture "$name" "$lock_text" "$runtime_text"
  assert_failure assert_profiler_version_contract \
    "$PROFILER_VERSION_CONTRACT_LOCK_FILE" \
    "$PROFILER_VERSION_CONTRACT_RUNTIME_FILE"
}

assert_profiler_version_contract_fixtures() {
  assert_profiler_version_contract_fixture_success \
    exact-match \
    $'version=4.5\n' \
    $'ASPROF_EXPECTED_VERSION="4.5"\n'
  assert_profiler_version_contract_fixture_success \
    crlf-lock \
    $'version=4.5\r\n' \
    $'ASPROF_EXPECTED_VERSION="4.5"\n'
  assert_profiler_version_contract_fixture_failure \
    version-drift \
    $'version=4.6\n' \
    $'ASPROF_EXPECTED_VERSION="4.5"\n'
  assert_profiler_version_contract_fixture_failure \
    missing-lock \
    $'tag=v4.5\n' \
    $'ASPROF_EXPECTED_VERSION="4.5"\n'
  assert_profiler_version_contract_fixture_failure \
    duplicate-lock \
    $'version=4.5\nversion=4.6\n' \
    $'ASPROF_EXPECTED_VERSION="4.5"\n'
  assert_profiler_version_contract_fixture_failure \
    malformed-lock \
    $'version =4.5\n' \
    $'ASPROF_EXPECTED_VERSION="4.5"\n'
  assert_profiler_version_contract_fixture_failure \
    empty-lock \
    $'version=\n' \
    $'ASPROF_EXPECTED_VERSION="4.5"\n'
  assert_profiler_version_contract_fixture_failure \
    missing-runtime \
    $'version=4.5\n' \
    $'ASPROF_HOME="/opt/async-profiler"\n'
  assert_profiler_version_contract_fixture_failure \
    duplicate-runtime \
    $'version=4.5\n' \
    $'ASPROF_EXPECTED_VERSION="4.5"\nASPROF_EXPECTED_VERSION="4.5"\n'
  assert_profiler_version_contract_fixture_failure \
    unquoted-runtime \
    $'version=4.5\n' \
    $'ASPROF_EXPECTED_VERSION=4.5\n'
  assert_profiler_version_contract_fixture_failure \
    dynamic-runtime \
    $'version=4.5\n' \
    $'ASPROF_EXPECTED_VERSION="$(cat /version)"\n'
  assert_profiler_version_contract_fixture_failure \
    empty-runtime \
    $'version=4.5\n' \
    $'ASPROF_EXPECTED_VERSION=""\n'
}

JQ_BIN="$(require_jq)"
EXP001_JQ_BIN_CACHE="$JQ_BIN"
export EXP001_JQ_BIN_CACHE
tmp_parent="${TMPDIR:-/tmp}"
temp_root="$(mktemp -d "$tmp_parent/exp001-profiler-fixtures.XXXXXX")"
fake_tools="$temp_root/fake-tools"
fake_curl_log="$temp_root/fake-curl.log"
fake_asprof_log="$temp_root/fake-asprof.log"
fake_jfrconv_log="$temp_root/fake-jfrconv.log"
fake_jfr_log="$temp_root/fake-jfr.log"
write_fake_container_tools "$fake_tools"

cleanup() {
  local resolved_temp
  local resolved_parent
  resolved_temp="$(cd "$temp_root" 2>/dev/null && pwd -P || true)"
  resolved_parent="$(cd "$tmp_parent" && pwd -P)"
  case "$resolved_temp" in
    "$resolved_parent"/*) rm -rf "$temp_root" ;;
  esac
}
trap cleanup EXIT

assert_profiler_version_contract "$ASYNC_PROFILER_LOCK_FILE" "$CONTAINER_RUNNER" \
  || fail "async-profiler lock/runtime version contract failed"
assert_profiler_version_contract_fixtures
assert_async_profiler_lock
assert_profile_config
assert_docker_policy
assert_official_result_manifest

assert_success run_require_tool_fixture $'Async-profiler 4.5 built on Jul 13 2026\n' '' 0
assert_success run_require_tool_fixture $'async-profiler 4.5\n' '' 0
assert_success run_require_tool_fixture $'Async-profiler 4.5 built on Jul 13 2026\n' $'warning: non-version diagnostic\n' 0
assert_success run_require_tool_fixture $'Async-profiler 4.5 built on Jul 13 2026\r\n' '' 0
assert_failure run_require_tool_fixture $'Async-profiler 4.6 built on Jul 13 2026\n' '' 0
assert_failure run_require_tool_fixture $'Async-profiler 14.5 built on Jul 13 2026\n' '' 0
assert_failure run_require_tool_fixture $'Async-profiler 4.5.1 built on Jul 13 2026\n' '' 0
assert_failure run_require_tool_fixture $'Other-profiler 4.5\n' '' 0
assert_failure run_require_tool_fixture $'Async-profiler built on Jul 13 2026\n' '' 0
assert_failure run_require_tool_fixture $'Async-profiler 4.5 built with helper 1.2\n' '' 0
assert_failure run_require_tool_fixture '' $'Async-profiler 4.5 built on Jul 13 2026\n' 0
assert_failure run_require_tool_fixture $'Async-profiler 4.5 built on Jul 13 2026\n' '' 7
assert_failure run_require_tool_fixture $'Async-profiler 4.5\nextra\n' '' 0
assert_failure run_require_tool_fixture $'\033[31mAsync-profiler 4.5\033[0m\n' '' 0

aggregate_manifest="$temp_root/aggregate-manifest.json"
write_aggregate_manifest "$aggregate_manifest"
aggregate_actual="$temp_root/sample-aggregate.json"
jq_to_file "$aggregate_actual" -f "$AGGREGATE_FILTER" "$aggregate_manifest"
assert_text_file_lf_utf8_no_bom_final_newline "$aggregate_actual"
assert_bytes_equal "$PROFILER_EXPECTED_DIR/sample-aggregate.json" "$aggregate_actual"

assert_aggregation_invalid '.chunks[1].sequence = 1' duplicate-sequence
assert_aggregation_invalid '.chunks[1].sequence = 3' missing-sequence
assert_aggregation_invalid '.chunks[1].filename = .chunks[0].filename' duplicate-filename
assert_aggregation_invalid '.expectedChunkCount = 3' expected-count
assert_aggregation_invalid '.chunks[1].event = "alloc"' event-mismatch
assert_aggregation_invalid '.chunks[1].strategy = "jdbc"' strategy-mismatch
assert_aggregation_invalid '.chunks[1].counterKind = "allocationBytes"' counter-kind-mismatch
assert_aggregation_invalid '.chunks[1].workloadValid = false' workload-invalid
assert_aggregation_invalid '.totalRows = 1' total-rows-mismatch
assert_aggregation_invalid '.chunks[1].sourceArtifactSha256 = "bad"' source-sha-malformed
assert_aggregation_invalid '.chunks[1].collapsedContent = "no-counter\n"' malformed-line
assert_aggregation_invalid '.chunks[1].collapsedContent = "java.lang.Thread.run 0\n"' zero-counter
assert_aggregation_invalid '.counterKind = "allocationBytes"' cpu-allocation-mix

alloc_manifest="$temp_root/alloc-manifest.json"
"$JQ_BIN" '
  .profileId = "alloc-jpa"
  | .event = "alloc"
  | .cpuEngine = null
  | .strategy = "jpa"
  | .interval = "512k"
  | .counterKind = "allocationBytes"
  | .chunks[0].event = "alloc"
  | .chunks[0].strategy = "jpa"
  | .chunks[0].counterKind = "allocationBytes"
  | .chunks[0].collapsedContent = "com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService.saveAll 100\n"
  | .chunks[1].event = "alloc"
  | .chunks[1].strategy = "jpa"
  | .chunks[1].counterKind = "allocationBytes"
  | .chunks[1].collapsedContent = "com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService.saveAll 300\n"
' "$aggregate_manifest" >"$alloc_manifest"
alloc_normalized="$("$JQ_BIN" -f "$AGGREGATE_FILTER" "$alloc_manifest" | "$JQ_BIN" -r '.normalizedSampledValuePer50000Rows')"
[[ "$alloc_normalized" == "200" ]] || fail "allocation normalization mismatch: $alloc_normalized"

assert_profile_summary_valid "$PROFILER_FIXTURES_DIR/valid-summary.json"
assert_profile_summary_invalid "$PROFILER_FIXTURES_DIR/invalid-engine-summary.json"
for filter in \
  '. + {hostname: "host01"}' \
  '.profiles[0] += {pid: 1234}' \
  '.profiles[0].workloadGate += {commandLine: "java -jar app.jar"}' \
  '.profiles[0].artifactManifest[0].fileName = "C:\\Users\\name\\profile.jfr"' \
  '.profiles[0].topPackages[0] += {extra: "x"}' \
  '.phase = "C:\\Users\\name\\file.txt"' \
  '.phase = "/home/user/file.txt"' \
  'del(.phase)'; do
  summary="$temp_root/invalid-summary-$(printf '%s' "$filter" | sha256sum | awk '{print $1}').json"
  "$JQ_BIN" "$filter" "$PROFILER_FIXTURES_DIR/valid-summary.json" >"$summary"
  assert_profile_summary_invalid "$summary"
done

uid="$(id -u)"
fake_proc="$temp_root/proc"
jcmd_file="$temp_root/jcmd.txt"
write_fake_proc "$fake_proc" 123 "$uid"
printf '123 /app/app.jar\n' >"$jcmd_file"
assert_success run_container_fixture "$fake_proc" "$jcmd_file" fixture-find-pid
assert_success run_container_fixture "$fake_proc" "$jcmd_file" fixture-verify-identity 123 987654
assert_failure run_container_fixture "$fake_proc" "$jcmd_file" fixture-verify-identity 123 1
printf '' >"$jcmd_file"
assert_failure run_container_fixture "$fake_proc" "$jcmd_file" fixture-find-pid
write_fake_proc "$fake_proc" 124 "$uid"
printf '123 /app/app.jar\n124 /app/app.jar\n' >"$jcmd_file"
assert_failure run_container_fixture "$fake_proc" "$jcmd_file" fixture-find-pid
wrong_proc="$temp_root/wrong-proc"
write_fake_proc "$wrong_proc" 123 "$uid" /app/wrong.jar
printf '123 /app/wrong.jar\n' >"$jcmd_file"
assert_failure run_container_fixture "$wrong_proc" "$jcmd_file" fixture-find-pid
wrong_profile_proc="$temp_root/wrong-profile-proc"
write_fake_proc "$wrong_profile_proc" 123 "$uid" /app/app.jar dev
printf '123 /app/app.jar\n' >"$jcmd_file"
assert_failure run_container_fixture "$wrong_profile_proc" "$jcmd_file" fixture-find-pid
wrong_uid_proc="$temp_root/wrong-uid-proc"
write_fake_proc "$wrong_uid_proc" 123 999999
assert_failure run_container_fixture "$wrong_uid_proc" "$jcmd_file" fixture-find-pid

assert_success run_container_fixture '' '' fixture-validate-inputs cpu-jpa cpu cpu jpa 10ms 1 50000
assert_success run_container_fixture '' '' fixture-validate-inputs cpu-jpa ctimer ctimer jpa 10ms 1 50000
assert_failure run_container_fixture '' '' fixture-validate-inputs cpu-jpa wall cpu jpa 10ms 1 50000
assert_failure run_container_fixture '' '' fixture-validate-inputs cpu-jpa cpu cpu orm 10ms 1 50000
assert_failure run_container_fixture '' '' fixture-validate-inputs cpu-jpa cpu wall jpa 10ms 1 50000
assert_failure run_container_fixture '' '' fixture-validate-inputs cpu-jpa cpu cpu jpa 11ms 1 50000
assert_failure run_container_fixture '' '' fixture-validate-inputs cpu-jpa cpu cpu jpa 10ms 0 50000
assert_failure run_container_fixture '' '' fixture-validate-inputs cpu-jpa cpu cpu jpa 10ms 1 49999
assert_failure run_container_fixture '' '' fixture-validate-inputs alloc-jpa cpu cpu jpa 10ms 1 50000
assert_failure run_container_fixture '' '' fixture-validate-output /tmp/escape.response.raw

ready_response="$temp_root/smoke-ready-response.json"
cpu_response="$temp_root/smoke-cpu-response.json"
allocation_response="$temp_root/smoke-allocation-response.json"
write_json_fixture "$ready_response" '{"status":"READY","phase":"EXP001_SMOKE"}'
write_json_fixture "$cpu_response" '{"success":true,"workload":"cpu","iterations":1000,"durationMillis":2500,"checksum":"0123456789abcdef"}'
write_json_fixture "$allocation_response" '{"success":true,"workload":"allocation","allocatedBytes":67108864,"chunkBytes":1048576,"chunks":64,"checksum":"fedcba9876543210"}'
assert_success run_container_fixture '' '' fixture-assert-ready-response "$ready_response"
assert_success run_container_fixture '' '' fixture-assert-cpu-response "$cpu_response"
assert_success run_container_fixture '' '' fixture-assert-allocation-response "$allocation_response"
assert_response_fixture_success ready-reordered fixture-assert-ready-response '{"phase":"EXP001_SMOKE","status":"READY"}'

assert_response_fixture_failure ready-status-missing fixture-assert-ready-response '{"phase":"EXP001_SMOKE"}'
assert_response_fixture_failure ready-status-wrong fixture-assert-ready-response '{"status":"STARTING","phase":"EXP001_SMOKE"}'
assert_response_fixture_failure ready-phase-missing fixture-assert-ready-response '{"status":"READY"}'
assert_response_fixture_failure ready-phase-wrong fixture-assert-ready-response '{"status":"READY","phase":"POSTGRESQL_READY"}'
assert_response_fixture_failure ready-unknown-field fixture-assert-ready-response '{"status":"READY","phase":"EXP001_SMOKE","extra":"x"}'
assert_response_fixture_failure ready-malformed fixture-assert-ready-response '{"status":"READY","phase":'
assert_response_fixture_failure ready-truncated fixture-assert-ready-response '{"status":"READY"'
assert_response_fixture_failure ready-trailing-garbage fixture-assert-ready-response '{"status":"READY","phase":"EXP001_SMOKE"} trailing'
assert_response_fixture_failure ready-duplicate-key fixture-assert-ready-response '{"status":"READY","status":"READY","phase":"EXP001_SMOKE"}'
assert_response_fixture_failure ready-wrong-type fixture-assert-ready-response '{"status":true,"phase":"EXP001_SMOKE"}'

assert_response_fixture_failure cpu-low-duration fixture-assert-cpu-response '{"success":true,"workload":"cpu","iterations":1000,"durationMillis":2499,"checksum":"0123456789abcdef"}'
assert_response_fixture_failure cpu-wrong-boolean fixture-assert-cpu-response '{"success":"true","workload":"cpu","iterations":1000,"durationMillis":2500,"checksum":"0123456789abcdef"}'
assert_response_fixture_failure cpu-wrong-workload fixture-assert-cpu-response '{"success":true,"workload":"allocation","iterations":1000,"durationMillis":2500,"checksum":"0123456789abcdef"}'
assert_response_fixture_failure cpu-negative-integer fixture-assert-cpu-response '{"success":true,"workload":"cpu","iterations":-1,"durationMillis":2500,"checksum":"0123456789abcdef"}'
assert_response_fixture_failure cpu-decimal-integer fixture-assert-cpu-response '{"success":true,"workload":"cpu","iterations":1000,"durationMillis":2500.5,"checksum":"0123456789abcdef"}'
assert_response_fixture_failure cpu-integer-overflow fixture-assert-cpu-response '{"success":true,"workload":"cpu","iterations":9223372036854775808,"durationMillis":2500,"checksum":"0123456789abcdef"}'
assert_response_fixture_failure cpu-invalid-checksum fixture-assert-cpu-response '{"success":true,"workload":"cpu","iterations":1000,"durationMillis":2500,"checksum":"0123456789ABCDEF"}'
assert_response_fixture_failure cpu-missing-key fixture-assert-cpu-response '{"success":true,"workload":"cpu","durationMillis":2500,"checksum":"0123456789abcdef"}'

assert_response_fixture_failure allocation-byte-mismatch fixture-assert-allocation-response '{"success":true,"workload":"allocation","allocatedBytes":67108863,"chunkBytes":1048576,"chunks":64,"checksum":"fedcba9876543210"}'
assert_response_fixture_failure allocation-number-string fixture-assert-allocation-response '{"success":true,"workload":"allocation","allocatedBytes":"67108864","chunkBytes":1048576,"chunks":64,"checksum":"fedcba9876543210"}'

large_response="$temp_root/smoke-response-too-large.json"
: >"$large_response"
for _ in $(seq 1 4097); do
  printf 'x' >>"$large_response"
done
assert_failure run_container_fixture '' '' fixture-assert-ready-response "$large_response"

http_ok="$temp_root/http-ok.response.raw"
assert_success env \
  EXP001_CURL_BIN="$fake_tools/bin/curl" \
  EXP001_FAKE_CURL_BODY="$ready_response" \
  EXP001_FAKE_CURL_LOG="$fake_curl_log" \
  EXP001_FAKE_CURL_STATUS=200 \
  SPRING_PROFILES_ACTIVE=exp001 \
  "$CONTAINER_RUNNER" fixture-http-request GET http://127.0.0.1:8080/internal/exp-001/smoke/ready "$http_ok" 200 2
http_conflict="$temp_root/http-conflict.response.raw"
assert_failure env \
  EXP001_CURL_BIN="$fake_tools/bin/curl" \
  EXP001_FAKE_CURL_BODY="$ready_response" \
  EXP001_FAKE_CURL_LOG="$fake_curl_log" \
  EXP001_FAKE_CURL_STATUS=409 \
  SPRING_PROFILES_ACTIVE=exp001 \
  "$CONTAINER_RUNNER" fixture-http-request POST http://127.0.0.1:8080/internal/exp-001/smoke/cpu "$http_conflict" 200 2
http_server_error="$temp_root/http-server-error.response.raw"
assert_failure env \
  EXP001_CURL_BIN="$fake_tools/bin/curl" \
  EXP001_FAKE_CURL_BODY="$ready_response" \
  EXP001_FAKE_CURL_LOG="$fake_curl_log" \
  EXP001_FAKE_CURL_STATUS=500 \
  SPRING_PROFILES_ACTIVE=exp001 \
  "$CONTAINER_RUNNER" fixture-http-request POST http://127.0.0.1:8080/internal/exp-001/smoke/cpu "$http_server_error" 200 2
http_large="$temp_root/http-large.response.raw"
assert_failure env \
  EXP001_CURL_BIN="$fake_tools/bin/curl" \
  EXP001_FAKE_CURL_BODY="$large_response" \
  EXP001_FAKE_CURL_LOG="$fake_curl_log" \
  EXP001_FAKE_CURL_STATUS=200 \
  SPRING_PROFILES_ACTIVE=exp001 \
  "$CONTAINER_RUNNER" fixture-http-request GET http://127.0.0.1:8080/internal/exp-001/smoke/ready "$http_large" 200 2

counter_good="$temp_root/counter-good.collapsed"
counter_zero="$temp_root/counter-zero.collapsed"
counter_malformed="$temp_root/counter-malformed.collapsed"
counter_overflow="$temp_root/counter-overflow.collapsed"
printf 'a;b 1\nc 2\n' >"$counter_good"
printf 'a;b 0\n' >"$counter_zero"
printf 'a;b nope\n' >"$counter_malformed"
printf 'a;b 9007199254740992\n' >"$counter_overflow"
assert_success run_container_fixture '' '' fixture-collapsed-total "$counter_good"
assert_failure run_container_fixture '' '' fixture-collapsed-total "$counter_zero"
assert_failure run_container_fixture '' '' fixture-collapsed-total "$counter_malformed"
assert_failure run_container_fixture '' '' fixture-collapsed-total "$counter_overflow"

engine_good="$temp_root/engine-good.json"
engine_ctimer="$temp_root/engine-ctimer.json"
engine_duplicate="$temp_root/engine-duplicate.json"
engine_no_active_setting="$temp_root/engine-no-active-setting.json"
engine_missing="$temp_root/engine-missing.json"
engine_unknown="$temp_root/engine-unknown.json"
engine_unrelated="$temp_root/engine-unrelated.json"
engine_stack_only="$temp_root/engine-stack-only.json"
engine_malformed="$temp_root/engine-malformed.json"
cat >"$engine_good" <<'JSON'
{"recording":{"events":[{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"perf_events"}}]}}
JSON
cat >"$engine_ctimer" <<'JSON'
{"recording":{"events":[{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"ctimer"}}]}}
JSON
cat >"$engine_duplicate" <<'JSON'
{"recording":{"events":[{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"perf_events"}},{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"ctimer"}}]}}
JSON
cat >"$engine_no_active_setting" <<'JSON'
{"recording":{"events":[{"type":"jdk.CPULoad","values":{"name":"engine","value":"perf_events"}}]}}
JSON
cat >"$engine_missing" <<'JSON'
{"recording":{"events":[{"type":"jdk.ActiveSetting","values":{"name":"period","value":"10 ms"}}]}}
JSON
cat >"$engine_unknown" <<'JSON'
{"recording":{"events":[{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"itimer"}}]}}
JSON
cat >"$engine_unrelated" <<'JSON'
{"recording":{"events":[{"type":"com.example.StackFrame","values":{"method":"com.example.ctimer.Engine","engine":"ctimer"}},{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"perf_events"}}]}}
JSON
cat >"$engine_stack_only" <<'JSON'
{"recording":{"events":[{"type":"com.example.StackFrame","values":{"method":"com.example.ctimer.Engine","engine":"ctimer"}}]}}
JSON
cat >"$engine_malformed" <<'JSON'
{"recording":{"events":[{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"perf_events"}}]
JSON
assert_success run_container_fixture '' '' fixture-parse-engine "$engine_good"
assert_success run_container_fixture '' '' fixture-parse-engine "$engine_ctimer"
assert_success run_container_fixture '' '' fixture-parse-engine "$engine_unrelated"
assert_failure run_container_fixture '' '' fixture-parse-engine "$engine_duplicate"
assert_failure run_container_fixture '' '' fixture-parse-engine "$engine_no_active_setting"
assert_failure run_container_fixture '' '' fixture-parse-engine "$engine_missing"
assert_failure run_container_fixture '' '' fixture-parse-engine "$engine_unknown"
assert_failure run_container_fixture '' '' fixture-parse-engine "$engine_stack_only"
assert_failure run_container_fixture '' '' fixture-parse-engine "$engine_malformed"

smoke_fixture_proc="$temp_root/smoke-proc"
write_fake_proc "$smoke_fixture_proc" 123 "$uid"
smoke_jcmd_file="$temp_root/smoke-jcmd.txt"
printf '123 /app/app.jar\n' >"$smoke_jcmd_file"
reset_fake_tool_logs
smoke_artifact_root="$temp_root/full-smoke-artifacts"
smoke_marker_id="smoke-marker-ctimer"
assert_success run_fake_smoke "$smoke_fixture_proc" "$smoke_jcmd_file" "$smoke_artifact_root" "$smoke_marker_id" \
  "$ready_response" "$cpu_response" "$allocation_response" "$engine_ctimer"
smoke_marker="$smoke_artifact_root/$smoke_marker_id/raw/smoke/smoke-ready.json"
assert_file_contains "$smoke_marker" '"markerFormatVersion":2'
assert_file_contains "$smoke_marker" '"selectedCpuEngine":"ctimer"'
assert_file_contains "$smoke_marker" '"engineVerification":"jfr-active-setting-engine:ctimer"'

cpu_bad_for_smoke="$temp_root/smoke-cpu-bad-response.json"
write_json_fixture "$cpu_bad_for_smoke" '{"success":true,"workload":"cpu","iterations":1000,"durationMillis":2499,"checksum":"0123456789abcdef"}'

reset_fake_tool_logs
smoke_success_dir="$temp_root/smoke-event-success"
mkdir -p "$smoke_success_dir"
assert_success run_fake_smoke_event "$smoke_fixture_proc" "$smoke_success_dir" "$cpu_response" "$engine_good"
assert_file_contains "$fake_asprof_log" 'start -e cpu -i 10ms 123'
assert_file_contains "$fake_asprof_log" 'stop -o jfr -f'
assert_file_contains "$fake_jfrconv_log" '--cpu --dot --norm -o collapsed'
assert_file_contains "$fake_jfr_log" 'print --json --events jdk.ActiveSetting'

reset_fake_tool_logs
smoke_start_fail_dir="$temp_root/smoke-event-start-fail"
mkdir -p "$smoke_start_fail_dir"
assert_failure run_fake_smoke_event "$smoke_fixture_proc" "$smoke_start_fail_dir" "$cpu_response" "$engine_good" EXP001_FAKE_ASPROF_START_FAIL=1
assert_file_contains "$fake_asprof_log" 'start -e cpu -i 10ms 123'
assert_file_not_contains "$fake_asprof_log" 'stop'
assert_file_not_contains "$fake_curl_log" 'curl'

reset_fake_tool_logs
smoke_http_fail_dir="$temp_root/smoke-event-http-fail"
mkdir -p "$smoke_http_fail_dir"
assert_failure run_fake_smoke_event "$smoke_fixture_proc" "$smoke_http_fail_dir" "$cpu_response" "$engine_good" EXP001_FAKE_CURL_STATUS=500
assert_file_contains "$fake_asprof_log" 'start -e cpu -i 10ms 123'
assert_file_contains "$fake_asprof_log" 'stop 123'
assert_file_not_contains "$fake_asprof_log" 'stop -o jfr -f'

reset_fake_tool_logs
smoke_response_fail_dir="$temp_root/smoke-event-response-fail"
mkdir -p "$smoke_response_fail_dir"
assert_failure run_fake_smoke_event "$smoke_fixture_proc" "$smoke_response_fail_dir" "$cpu_bad_for_smoke" "$engine_good"
assert_file_contains "$fake_asprof_log" 'start -e cpu -i 10ms 123'
assert_file_contains "$fake_asprof_log" 'stop 123'
assert_file_not_contains "$fake_jfrconv_log" '--cpu --dot --norm -o collapsed'

reset_fake_tool_logs
write_fake_proc "$smoke_fixture_proc" 123 "$uid"
smoke_identity_fail_dir="$temp_root/smoke-event-identity-fail"
mkdir -p "$smoke_identity_fail_dir"
assert_failure run_fake_smoke_event "$smoke_fixture_proc" "$smoke_identity_fail_dir" "$cpu_response" "$engine_good" \
  EXP001_FAKE_IDENTITY_AFTER_CURL=111111 EXP001_FAKE_PROC_ROOT="$smoke_fixture_proc" EXP001_FAKE_PID=123
assert_file_contains "$fake_asprof_log" 'start -e cpu -i 10ms 123'
assert_file_contains "$fake_asprof_log" 'stop 123'

reset_fake_tool_logs
write_fake_proc "$smoke_fixture_proc" 123 "$uid"
smoke_stop_fail_dir="$temp_root/smoke-event-stop-fail"
mkdir -p "$smoke_stop_fail_dir"
assert_failure run_fake_smoke_event "$smoke_fixture_proc" "$smoke_stop_fail_dir" "$cpu_response" "$engine_good" EXP001_FAKE_ASPROF_STOP_FAIL=1
assert_file_contains "$fake_asprof_log" 'stop -o jfr -f'
assert_file_not_contains "$fake_jfrconv_log" '--cpu --dot --norm -o collapsed'

reset_fake_tool_logs
smoke_conversion_fail_dir="$temp_root/smoke-event-conversion-fail"
mkdir -p "$smoke_conversion_fail_dir"
assert_failure run_fake_smoke_event "$smoke_fixture_proc" "$smoke_conversion_fail_dir" "$cpu_response" "$engine_good" EXP001_FAKE_JFRCONV_FAIL=1
assert_file_contains "$fake_asprof_log" 'stop -o jfr -f'
assert_file_contains "$fake_jfrconv_log" '--cpu --dot --norm -o collapsed'

for path in \
  scripts/exp-001/tests/profiler/fixtures/valid-summary.json \
  scripts/exp-001/tests/profiler/fixtures/sample.collapsed \
  scripts/exp-001/tests/profiler/expected/sample-aggregate.json \
  scripts/exp-001/tests/profiler/expected/metadata-snippet.md; do
  assert_git_attr "$path" text set
  assert_git_attr "$path" eol lf
done

assert_git_attr results/exp-001/20260727T053643Z-2d76b26/summary.md text unset
assert_git_attr results/exp-001/20260727T053643Z-2d76b26/summary.md whitespace cr-at-eol
assert_git_ignored artifacts/exp-001/profiling/demo/raw/cpu.jfr
assert_git_ignored results/exp-001/profiling/demo/cpu.jfr
assert_git_not_ignored results/exp-001/profiling/demo/summary.json
assert_git_not_ignored results/exp-001/profiling/demo/metadata.md
assert_git_not_ignored results/exp-001/profiling/demo/analysis.md
assert_git_not_ignored results/exp-001/profiling/demo/manifest.md

printf 'EXP-001 profiler fixture tests passed.\n'
