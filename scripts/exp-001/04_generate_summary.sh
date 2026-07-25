#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

latest_run_dir() {
  find "$RESULT_ROOT_ABS" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
}

main() {
  require_command jq
  require_command awk
  assert_project_root
  ensure_directories

  local run_dir="${1:-}"
  if [[ "$run_dir" == "" ]]; then
    run_dir="$(latest_run_dir)"
  fi
  [[ "$run_dir" != "" ]] || die "summary를 생성할 run directory를 찾지 못했습니다."
  [[ -d "$run_dir/official" ]] || die "official JSON directory가 없습니다: $run_dir/official"

  local summary_file="$run_dir/summary.md"
  local stats_file="$run_dir/official/.stats.tsv"

  jq -r 'select(.valid == true) | [.path, .inputCount, .elapsedNanos] | @tsv' "$run_dir"/official/*.json >"$stats_file"

  LC_ALL=C awk -v summary_file="$summary_file" '
    function add(path, input_count, elapsed) {
      n[path]++
      elapsed_values[path, n[path]] = elapsed
      throughput_values[path, n[path]] = input_count * 1000000000 / elapsed
    }
    function sort_numbers(source, count, sorted,    i, j, temp) {
      for (i = 1; i <= count; i++) {
        sorted[i] = source[i]
      }
      for (i = 1; i <= count; i++) {
        for (j = i + 1; j <= count; j++) {
          if (sorted[j] < sorted[i]) {
            temp = sorted[i]
            sorted[i] = sorted[j]
            sorted[j] = temp
          }
        }
      }
    }
    function median_elapsed(path,    i, values, sorted) {
      for (i = 1; i <= n[path]; i++) values[i] = elapsed_values[path, i]
      sort_numbers(values, n[path], sorted)
      return (sorted[3] + sorted[4]) / 2
    }
    function median_throughput(path,    i, values, sorted) {
      for (i = 1; i <= n[path]; i++) values[i] = throughput_values[path, i]
      sort_numbers(values, n[path], sorted)
      return (sorted[3] + sorted[4]) / 2
    }
    function stats(path, metric,    i, value, sum, mean, min, max, diff, variance, stddev, cv) {
      min = ""
      max = ""
      sum = 0
      for (i = 1; i <= n[path]; i++) {
        value = metric == "elapsed" ? elapsed_values[path, i] : throughput_values[path, i]
        if (min == "" || value < min) min = value
        if (max == "" || value > max) max = value
        sum += value
      }
      mean = sum / n[path]
      variance = 0
      for (i = 1; i <= n[path]; i++) {
        value = metric == "elapsed" ? elapsed_values[path, i] : throughput_values[path, i]
        diff = value - mean
        variance += diff * diff
      }
      stddev = sqrt(variance / (n[path] - 1))
      cv = mean == 0 ? 0 : stddev / mean * 100
      return sprintf("| %s | %s | %.3f | %.3f | %.3f | %.3f | %.3f | %.2f%% |", path, metric, min, max, mean, metric == "elapsed" ? median_elapsed(path) : median_throughput(path), stddev, cv)
    }
    BEGIN {
      FS = "\t"
    }
    {
      if ($3 <= 0) {
        print "elapsedNanos must be positive" > "/dev/stderr"
        exit 2
      }
      add($1, $2, $3)
    }
    END {
      if (n["jpa"] != 6 || n["jdbc"] != 6) {
        print "official valid result count must be exactly 6 per path" > "/dev/stderr"
        exit 2
      }
      jpa_median = median_elapsed("jpa")
      jdbc_median = median_elapsed("jdbc")
      time_reduction = jpa_median == 0 ? 0 : (jpa_median - jdbc_median) / jpa_median * 100
      speedup = jdbc_median == 0 ? 0 : jpa_median / jdbc_median

      print "# EXP-001 Summary" > summary_file
      print "" >> summary_file
      print "Warm-up 결과는 제외하고 official valid JSON만 사용했다." >> summary_file
      print "" >> summary_file
      print "## Metrics" >> summary_file
      print "" >> summary_file
      print "| path | metric | min | max | mean | median | sample stddev | CV |" >> summary_file
      print "|---|---:|---:|---:|---:|---:|---:|---:|" >> summary_file
      print stats("jpa", "elapsed") >> summary_file
      print stats("jdbc", "elapsed") >> summary_file
      print stats("jpa", "throughput") >> summary_file
      print stats("jdbc", "throughput") >> summary_file
      print "" >> summary_file
      print "## Comparison" >> summary_file
      print "" >> summary_file
      printf "- JDBC median elapsed 기준 time reduction: %.2f%%\n", time_reduction >> summary_file
      printf "- JDBC median elapsed 기준 speedup: %.6f\n", speedup >> summary_file
    }
  ' "$stats_file"

  rm -f "$stats_file"
  log "summary 생성 완료: $summary_file"
}

main "$@"
