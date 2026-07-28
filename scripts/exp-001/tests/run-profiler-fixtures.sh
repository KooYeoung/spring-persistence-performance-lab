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
ASYNC_PROFILER_LOCK_FILE="$TEST_PROJECT_ROOT/scripts/exp-001/tools/async-profiler.lock"
DOCKER_DIR="$PROFILER_ROOT/docker"
CONTAINER_RUNNER="$PROFILER_ROOT/container/exp001-profile.sh"

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

JQ_BIN="$(require_jq)"
EXP001_JQ_BIN_CACHE="$JQ_BIN"
export EXP001_JQ_BIN_CACHE
tmp_parent="${TMPDIR:-/tmp}"
temp_root="$(mktemp -d "$tmp_parent/exp001-profiler-fixtures.XXXXXX")"

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

assert_async_profiler_lock
assert_profile_config
assert_docker_policy
assert_official_result_manifest

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
