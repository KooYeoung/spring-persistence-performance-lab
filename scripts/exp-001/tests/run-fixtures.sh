#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXP_ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
PROJECT_ROOT="$(cd "$EXP_ROOT/../.." && pwd -P)"
TEST_PROJECT_ROOT="$PROJECT_ROOT"
FIXTURES_DIR="$TEST_DIR/fixtures"
EXPECTED_DIR="$TEST_DIR/expected"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
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
      [[ -f "$override" ]] || fail "Windows locked jq를 찾을 수 없습니다: $override"
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

assert_validation_fails() {
  local mode="$1"
  local expected_path="$2"
  local file="$3"

  if "$JQ_BIN" -e --arg mode "$mode" --arg expectedPath "$expected_path" --argjson expectedCount 50000 -f "$EXP001_VALIDATE_RESPONSE_FILTER" "$file" >/dev/null 2>/dev/null; then
    fail "validation unexpectedly passed: mode=$mode file=$file"
  fi
}

summary_file_names_json() {
  local file
  for file in "$@"; do
    basename "$file"
  done | "$JQ_BIN" -R -s -c 'split("\n") | map(select(length > 0))'
}

summary_to_file() {
  local destination="$1"
  local official_file_names_json="$2"
  shift 2

  jq_to_file "$destination" \
    -r \
    --argjson expectedCount 50000 \
    --argjson officialFileNames "$official_file_names_json" \
    -s \
    -f "$EXP001_SUMMARY_FILTER" \
    "$@"
}

assert_summary_fails() {
  local destination="$1"
  local official_file_names_json="$2"
  shift 2

  if summary_to_file "$destination" "$official_file_names_json" "$@" >/dev/null 2>/dev/null; then
    fail "summary unexpectedly passed: $destination"
  fi
  [[ ! -e "$destination" ]] || fail "failed summary left partial file: $destination"
}

write_summary_record() {
  local output="$1"
  local strategy="$2"
  local nanos="$3"
  local v2="$4"
  local checksum="$5"

  jq_to_file "$output" \
    -n \
    --arg path "$strategy" \
    --arg checksum "$checksum" \
    --argjson nanos "$nanos" \
    --argjson v2 "$v2" \
    '
      {
        path: $path,
        inputCount: 50000,
        savedCount: 50000,
        elapsedNanos: $nanos,
        elapsedMillis: ($nanos / 1000000),
        valid: true,
        rowCount: 50000,
        distinctBusinessKeyCount: 50000,
        missingKeyCount: 0,
        unexpectedKeyCount: 0,
        duplicateKeyCount: 0,
        expectedChecksum: $checksum,
        actualChecksum: $checksum
      } as $base
      | if $v2 then
          {resultFormatVersion: 2}
          + ($base | {path, inputCount, savedCount, elapsedNanos})
          + {elapsedSeconds: ($nanos / 1000000000)}
          + ($base | {elapsedMillis, valid, rowCount, distinctBusinessKeyCount, missingKeyCount, unexpectedKeyCount, duplicateKeyCount, expectedChecksum, actualChecksum})
        else
          $base
        end
    '
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

assert_official_result_sha() {
  local result_root="$TEST_PROJECT_ROOT/results/exp-001/20260727T053643Z-2d76b26"
  local count
  count="$(find "$result_root" -type f | wc -l | tr -d ' ')"
  [[ "$count" == "16" ]] || fail "official result file count changed: $count"

  local manifest
  manifest='
results/exp-001/20260727T053643Z-2d76b26/metadata.md 52116dca40b7834dac8a6f868e8030677665b885d90743605c8d2299f74ad2ac
results/exp-001/20260727T053643Z-2d76b26/official/round-01-01-jpa.json 82d1ef9c3fcf9c148d36980bc03aad0ad2a6e3b9f49cb79f3c750bce3cbb3734
results/exp-001/20260727T053643Z-2d76b26/official/round-01-02-jdbc.json a3a02fba1cb0c6ed81a77fd537853d59b91e9e8f094c22ef3d568c116548ee51
results/exp-001/20260727T053643Z-2d76b26/official/round-02-01-jdbc.json ebec41d3feb15efe2211a8bf93eaa4477062b8d7539b51f94f89f01d39961d7a
results/exp-001/20260727T053643Z-2d76b26/official/round-02-02-jpa.json 6179a1dfbaa3e8b9b56e812b795d4f8880b2791ca9f2a5638ee9ac8c16297065
results/exp-001/20260727T053643Z-2d76b26/official/round-03-01-jpa.json ef44140747df9786eefb9d194c30074e9780cc0678335e35664da32ed7594cc2
results/exp-001/20260727T053643Z-2d76b26/official/round-03-02-jdbc.json 63b11a2d48bdf7344f0f148e46ef9cab4ac6f99267a2423f0432d6f84bd2d1fe
results/exp-001/20260727T053643Z-2d76b26/official/round-04-01-jdbc.json ad3272786a4f19ac8a6aa349beb39c6ff2abb9da5f00a7de6910a149941c2e5f
results/exp-001/20260727T053643Z-2d76b26/official/round-04-02-jpa.json 791e819059c2f8bd539005caad2291100974b3f96477fa96c40edacb90abf8b3
results/exp-001/20260727T053643Z-2d76b26/official/round-05-01-jpa.json 5f7b93343438b1db1c1d4290f57bda04dae1120ca805896122df67c0f890c1e8
results/exp-001/20260727T053643Z-2d76b26/official/round-05-02-jdbc.json 74f6b0bb1e672381c00c1ed56897aa6d6c60be35e18be54faa953776aef1addc
results/exp-001/20260727T053643Z-2d76b26/official/round-06-01-jdbc.json 7321a74581900a3ad3d6ec1f3bc30eb32be3d4aa005f54a456fdf1add9e96117
results/exp-001/20260727T053643Z-2d76b26/official/round-06-02-jpa.json 47039a6a0ff8c03bde0687a751fc602bb27a99c7da701a66e3b0f6bc3d359d96
results/exp-001/20260727T053643Z-2d76b26/summary.md 4acf86bf224859b02635db879c04f5cb92af306cdfe2cddcc3de9ffac53cb6df
results/exp-001/20260727T053643Z-2d76b26/warmup/01-jpa-warmup.json ca6754161d2888f0f6afa8a2a00dab85f3c8e6e279327ee0d063254958307fd2
results/exp-001/20260727T053643Z-2d76b26/warmup/02-jdbc-warmup.json 94e6533c7ed9691b6aaba93caa9b176b969949e998c635ab3b507015a033014c
'

  local relative
  local expected
  local actual
  while read -r relative expected; do
    [[ "$relative" != "" ]] || continue
    [[ -f "$TEST_PROJECT_ROOT/$relative" ]] || fail "official result file missing: $relative"
    actual="$(sha256_file "$TEST_PROJECT_ROOT/$relative")"
    [[ "$actual" == "$expected" ]] || fail "official result SHA changed: $relative"
  done <<<"$manifest"
}

JQ_BIN="$(require_jq)"
EXP001_JQ_BIN_CACHE="$JQ_BIN"
export EXP001_JQ_BIN_CACHE
tmp_parent="${TMPDIR:-/tmp}"
temp_root="$(mktemp -d "$tmp_parent/exp 001 fixtures.XXXXXX")"

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

legacy="$FIXTURES_DIR/legacy-compact-valid.json"
v2="$FIXTURES_DIR/v2-pretty-valid.json"
invalid_seconds="$FIXTURES_DIR/v2-invalid-seconds.json"
ambiguous="$FIXTURES_DIR/ambiguous-versionless-seconds.json"

verify_response "jpa" "$legacy" 50000 "raw"
verify_response "jpa" "$legacy" 50000 "artifact"
verify_response "jdbc" "$v2" 50000 "v2"
verify_response "jdbc" "$v2" 50000 "artifact"
assert_validation_fails "artifact" "jdbc" "$invalid_seconds"
assert_validation_fails "artifact" "jpa" "$ambiguous"
assert_validation_fails "raw" "jdbc" "$v2"

formatted="$temp_root/formatted output.json"
format_response "jpa" "$legacy" "$formatted" 50000
assert_bytes_equal "$EXPECTED_DIR/v2-formatted.json" "$formatted"
assert_text_file_lf_utf8_no_bom_final_newline "$formatted"
compare_formatted_response_semantics "$legacy" "$formatted"

for nanos in \
  1 \
  999 \
  1000000 \
  999999999 \
  1000000000 \
  60000000000 \
  80000000000 \
  75857631900 \
  1234567890; do
  edge_raw="$temp_root/edge-$nanos.raw.json"
  edge_formatted="$temp_root/edge-$nanos.formatted.json"
  jq_to_file "$edge_raw" --argjson nanos "$nanos" '.elapsedNanos = $nanos | .elapsedMillis = ($nanos / 1000000)' "$legacy"
  verify_response "jpa" "$edge_raw" 50000 "raw"
  format_response "jpa" "$edge_raw" "$edge_formatted" 50000
  verify_response "jpa" "$edge_formatted" 50000 "v2"
  assert_text_file_lf_utf8_no_bom_final_newline "$edge_formatted"
  compare_formatted_response_semantics "$edge_raw" "$edge_formatted"
done

bad_formatted="$temp_root/bad formatted.json"
if jq_to_file "$bad_formatted" --arg expectedPath "jpa" --argjson expectedCount 50000 -f "$EXP001_FORMAT_RESPONSE_FILTER" "$ambiguous" >/dev/null 2>/dev/null; then
  fail "formatter unexpectedly accepted ambiguous fixture"
fi
[[ ! -e "$bad_formatted" ]] || fail "failed formatter left partial file: $bad_formatted"

millis_mismatch="$temp_root/millis mismatch.json"
jq_to_file "$millis_mismatch" '.elapsedMillis = 1' "$legacy"
assert_validation_fails "raw" "jpa" "$millis_mismatch"

unknown_version="$temp_root/unknown version.json"
jq_to_file "$unknown_version" '.resultFormatVersion = 3' "$v2"
assert_validation_fails "artifact" "jdbc" "$unknown_version"

invalid_v2_filters=(
  'del(.elapsedSeconds)'
  '.elapsedSeconds = "1"'
  '.elapsedSeconds = null'
  '.elapsedSeconds = -1'
)
for index in "${!invalid_v2_filters[@]}"; do
  variant="$temp_root/v2 invalid $index.json"
  jq_to_file "$variant" "${invalid_v2_filters[$index]}" "$v2"
  assert_validation_fails "artifact" "jdbc" "$variant"
done

invalid_legacy_filters=(
  '.actualChecksum = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"'
  '.savedCount = 49999'
  '.rowCount = 49999'
  '.valid = false'
)
for index in "${!invalid_legacy_filters[@]}"; do
  variant="$temp_root/legacy invalid $index.json"
  jq_to_file "$variant" "${invalid_legacy_filters[$index]}" "$legacy"
  assert_validation_fails "raw" "jpa" "$variant"
done

empty_json="$temp_root/empty.json"
: >"$empty_json"
assert_validation_fails "artifact" "jpa" "$empty_json"

partial_json="$temp_root/partial.json"
printf '%s' '{"path":"jpa"' >"$partial_json"
assert_validation_fails "artifact" "jpa" "$partial_json"

summary_dir="$temp_root/official mixed"
mkdir -p "$summary_dir"
sha_a='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
sha_b='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
summary_files=()
summary_specs=(
  "round-01-01-jpa.json jpa 1000000000 false $sha_a"
  "round-01-02-jdbc.json jdbc 500000000 true $sha_b"
  "round-02-01-jdbc.json jdbc 600000000 false $sha_b"
  "round-02-02-jpa.json jpa 2000000000 true $sha_a"
  "round-03-01-jpa.json jpa 3000000000 false $sha_a"
  "round-03-02-jdbc.json jdbc 700000000 true $sha_b"
  "round-04-01-jdbc.json jdbc 800000000 false $sha_b"
  "round-04-02-jpa.json jpa 4000000000 true $sha_a"
  "round-05-01-jpa.json jpa 5000000000 false $sha_a"
  "round-05-02-jdbc.json jdbc 900000000 true $sha_b"
  "round-06-01-jdbc.json jdbc 1000000000 false $sha_b"
  "round-06-02-jpa.json jpa 6000000000 true $sha_a"
)
for spec in "${summary_specs[@]}"; do
  read -r file strategy nanos v2_flag checksum <<<"$spec"
  output="$summary_dir/$file"
  write_summary_record "$output" "$strategy" "$nanos" "$v2_flag" "$checksum"
  summary_files+=("$output")
done

summary_actual="$temp_root/summary actual.md"
official_file_names_json="$(summary_file_names_json "${summary_files[@]}")"
summary_to_file "$summary_actual" "$official_file_names_json" "${summary_files[@]}"
assert_text_file_lf_utf8_no_bom_final_newline "$summary_actual"
assert_bytes_equal "$EXPECTED_DIR/summary-mixed.md" "$summary_actual"

jpa_first_indexes=(0 3 4 7 8 11 1 2 5 6 9 10)
jpa_first_files=()
for index in "${jpa_first_indexes[@]}"; do
  jpa_first_files+=("${summary_files[$index]}")
done
assert_summary_fails "$temp_root/summary grouped order.md" "$(summary_file_names_json "${jpa_first_files[@]}")" "${jpa_first_files[@]}"

swapped_files=("${summary_files[@]}")
swapped_files[0]="${summary_files[1]}"
swapped_files[1]="${summary_files[0]}"
assert_summary_fails "$temp_root/summary swapped order.md" "$(summary_file_names_json "${swapped_files[@]}")" "${swapped_files[@]}"

duplicate_file_names_json="$(
  printf '%s\n' \
    "round-01-01-jpa.json" \
    "round-01-01-jpa.json" \
    "round-02-01-jdbc.json" \
    "round-02-02-jpa.json" \
    "round-03-01-jpa.json" \
    "round-03-02-jdbc.json" \
    "round-04-01-jdbc.json" \
    "round-04-02-jpa.json" \
    "round-05-01-jpa.json" \
    "round-05-02-jdbc.json" \
    "round-06-01-jdbc.json" \
    "round-06-02-jpa.json" \
    | "$JQ_BIN" -R -s -c 'split("\n") | map(select(length > 0))'
)"
assert_summary_fails "$temp_root/summary duplicate basename.md" "$duplicate_file_names_json" "${summary_files[@]}"

missing_files=("${summary_files[@]:0:11}")
assert_summary_fails "$temp_root/summary missing basename.md" "$(summary_file_names_json "${missing_files[@]}")" "${missing_files[@]}"

unexpected_file_names_json="$(
  printf '%s\n' \
    "round-01-01-jpa.json" \
    "round-01-02-jdbc.json" \
    "round-02-01-jdbc.json" \
    "round-02-02-jpa.json" \
    "round-03-01-jpa.json" \
    "round-03-02-jdbc.json" \
    "round-04-01-jdbc.json" \
    "round-04-02-jpa.json" \
    "round-05-01-jpa.json" \
    "round-05-02-jdbc.json" \
    "round-06-01-jdbc.json" \
    "round-06-02-saveall.json" \
    | "$JQ_BIN" -R -s -c 'split("\n") | map(select(length > 0))'
)"
assert_summary_fails "$temp_root/summary unexpected basename.md" "$unexpected_file_names_json" "${summary_files[@]}"

strategy_mismatch_files=("${summary_files[@]}")
strategy_mismatch_file="$temp_root/round-01-01-jpa-strategy-mismatch.json"
jq_to_file "$strategy_mismatch_file" '.path = "jdbc"' "${summary_files[0]}"
strategy_mismatch_files[0]="$strategy_mismatch_file"
assert_summary_fails "$temp_root/summary strategy mismatch.md" "$official_file_names_json" "${strategy_mismatch_files[@]}"

human_dir="$temp_root/official human duration"
mkdir -p "$human_dir"
human_nanos=(
  647975450
  8783400000
  75857631900
  76684628950
  3000000000
  700000000
  800000000
  4000000000
  5000000000
  900000000
  1000000000
  6000000000
)
human_files=()
for index in "${!summary_specs[@]}"; do
  read -r file strategy ignored_nanos v2_flag checksum <<<"${summary_specs[$index]}"
  output="$human_dir/$file"
  write_summary_record "$output" "$strategy" "${human_nanos[$index]}" "$v2_flag" "$checksum"
  human_files+=("$output")
done
human_summary="$temp_root/summary human duration.md"
summary_to_file "$human_summary" "$official_file_names_json" "${human_files[@]}"
grep -F '647.975ms' "$human_summary" >/dev/null || fail "human duration sub-second display mismatch"
grep -F '8.783s' "$human_summary" >/dev/null || fail "human duration seconds display mismatch"
grep -F '1m 15.858s' "$human_summary" >/dev/null || fail "human duration minute display mismatch"
grep -F '1m 16.685s' "$human_summary" >/dev/null || fail "human duration minute rounding mismatch"

promotion_dir="$temp_root/promotion with spaces"
mkdir -p "$promotion_dir"
promotion_temp="$promotion_dir/result.tmp"
promotion_final="$promotion_dir/result.json"
printf 'promoted\n' >"$promotion_temp"
promote_file_no_clobber "$promotion_temp" "$promotion_final" || fail "promotion success case failed"
[[ -f "$promotion_final" ]] || fail "promotion final missing"
[[ ! -e "$promotion_temp" ]] || fail "promotion temp was not removed"
printf 'promoted\n' | cmp -s - "$promotion_final" || fail "promotion final content mismatch"

existing_temp="$promotion_dir/existing.tmp"
existing_final="$promotion_dir/existing.json"
printf 'new\n' >"$existing_temp"
printf 'old\n' >"$existing_final"
existing_before="$(sha256_file "$existing_final")"
if promote_file_no_clobber "$existing_temp" "$existing_final" >/dev/null 2>/dev/null; then
  fail "promotion unexpectedly overwrote existing final"
fi
existing_after="$(sha256_file "$existing_final")"
[[ "$existing_before" == "$existing_after" ]] || fail "promotion changed existing final"
[[ -f "$existing_temp" ]] || fail "failed promotion removed temp unexpectedly"
rm -f "$existing_temp"

summary_promotion_temp="$promotion_dir/summary.tmp"
summary_promotion_final="$promotion_dir/summary.md"
printf '# summary\n' >"$summary_promotion_temp"
promote_file_no_clobber "$summary_promotion_temp" "$summary_promotion_final" || fail "summary promotion failed"
[[ -f "$summary_promotion_final" ]] || fail "summary promotion final missing"
[[ ! -e "$summary_promotion_temp" ]] || fail "summary promotion temp was not removed"

for path in \
  scripts/exp-001/tests/fixtures/legacy-compact-valid.json \
  scripts/exp-001/tests/expected/v2-formatted.json \
  scripts/exp-001/tests/expected/summary-mixed.md; do
  assert_git_attr "$path" text set
  assert_git_attr "$path" eol lf
done
assert_git_attr results/exp-001/20260727T053643Z-2d76b26/summary.md text unset
assert_git_attr results/exp-001/20260727T053643Z-2d76b26/summary.md whitespace cr-at-eol
assert_official_result_sha

printf 'EXP-001 fixture tests passed.\n'
