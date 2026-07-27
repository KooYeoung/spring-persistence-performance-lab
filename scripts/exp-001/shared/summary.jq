def sha256_checksum:
  type == "string" and test("^[0-9a-f]{64}$");

def positive_integer:
  type == "number" and . > 0 and floor == .;

def zero_integer:
  type == "number" and . == 0 and floor == .;

def finite_positive_number:
  type == "number" and . > 0;

def abs_value:
  if . < 0 then -. else . end;

def close_to($expected; $tolerance):
  finite_positive_number and ((. - $expected) | abs_value) <= $tolerance;

def elapsed_millis_valid($record):
  ($record.elapsedMillis | close_to(($record.elapsedNanos / 1000000); 0.0000005));

def elapsed_seconds_valid($record):
  ($record.elapsedSeconds | close_to(($record.elapsedNanos / 1000000000); 0.0000000005));

def valid_record($expectedCount):
  . as $record
  | type == "object"
  and ($record.valid == true)
  and (($record.path == "jpa") or ($record.path == "jdbc"))
  and ($record.inputCount | positive_integer)
  and ($record.inputCount == $expectedCount)
  and ($record.savedCount | positive_integer)
  and ($record.savedCount == $expectedCount)
  and ($record.rowCount | positive_integer)
  and ($record.rowCount == $expectedCount)
  and ($record.distinctBusinessKeyCount | positive_integer)
  and ($record.distinctBusinessKeyCount == $expectedCount)
  and ($record.elapsedNanos | positive_integer)
  and elapsed_millis_valid($record)
  and ($record.missingKeyCount | zero_integer)
  and ($record.unexpectedKeyCount | zero_integer)
  and ($record.duplicateKeyCount | zero_integer)
  and ($record.expectedChecksum | sha256_checksum)
  and ($record.actualChecksum | sha256_checksum)
  and ($record.expectedChecksum == $record.actualChecksum);

def legacy_record_valid($expectedCount):
  valid_record($expectedCount)
  and (has("resultFormatVersion") | not)
  and (has("elapsedSeconds") | not);

def v2_record_valid($expectedCount):
  . as $record
  | valid_record($expectedCount)
  and ($record.resultFormatVersion | type == "number" and . == 2 and floor == .)
  and (has("elapsedSeconds"))
  and elapsed_seconds_valid($record);

def artifact_record_valid($expectedCount):
  if has("resultFormatVersion") then
    v2_record_valid($expectedCount)
  elif has("elapsedSeconds") then
    false
  else
    legacy_record_valid($expectedCount)
  end;

def expected_official_metadata:
  [
    {sequence: 1, round: 1, position: 1, path: "jpa", basename: "round-01-01-jpa.json"},
    {sequence: 2, round: 1, position: 2, path: "jdbc", basename: "round-01-02-jdbc.json"},
    {sequence: 3, round: 2, position: 1, path: "jdbc", basename: "round-02-01-jdbc.json"},
    {sequence: 4, round: 2, position: 2, path: "jpa", basename: "round-02-02-jpa.json"},
    {sequence: 5, round: 3, position: 1, path: "jpa", basename: "round-03-01-jpa.json"},
    {sequence: 6, round: 3, position: 2, path: "jdbc", basename: "round-03-02-jdbc.json"},
    {sequence: 7, round: 4, position: 1, path: "jdbc", basename: "round-04-01-jdbc.json"},
    {sequence: 8, round: 4, position: 2, path: "jpa", basename: "round-04-02-jpa.json"},
    {sequence: 9, round: 5, position: 1, path: "jpa", basename: "round-05-01-jpa.json"},
    {sequence: 10, round: 5, position: 2, path: "jdbc", basename: "round-05-02-jdbc.json"},
    {sequence: 11, round: 6, position: 1, path: "jdbc", basename: "round-06-01-jdbc.json"},
    {sequence: 12, round: 6, position: 2, path: "jpa", basename: "round-06-02-jpa.json"}
  ];

def expected_official_file_names:
  [ expected_official_metadata[] | .basename ];

def duplicate_names($names):
  [
    reduce $names[] as $name ({}; .[$name] = ((.[$name] // 0) + 1))
    | to_entries[]
    | select(.value > 1)
    | .key
  ];

def unexpected_names($names):
  $names - expected_official_file_names;

def missing_names($names):
  expected_official_file_names - $names;

def filename_metadata($name):
  ($name | capture("^round-(?<roundText>[0-9]{2})-(?<positionText>[0-9]{2})-(?<path>jpa|jdbc)\\.json$")) as $match
  | {
      round: ($match.roundText | tonumber),
      position: ($match.positionText | tonumber),
      path: $match.path,
      basename: $name
    };

def require_file_name_gate($names):
  if ($names | type) != "array" then
    error("officialFileNames는 JSON array여야 합니다.")
  elif ($names | length) != 12 then
    error("official filename 수가 정확히 12개가 아닙니다: \($names | length)")
  elif any($names[]; type != "string") then
    error("official filename은 모두 string이어야 합니다.")
  elif (duplicate_names($names) | length) != 0 then
    error("duplicate official filename이 있습니다: \((duplicate_names($names)) | join(", "))")
  elif (missing_names($names) | length) != 0 then
    error("missing official filename이 있습니다: \((missing_names($names)) | join(", "))")
  elif (unexpected_names($names) | length) != 0 then
    error("unexpected official filename이 있습니다: \((unexpected_names($names)) | join(", "))")
  elif $names != expected_official_file_names then
    error("official filename order가 기대 순서와 다릅니다.")
  else
    $names
  end;

def path_count($path):
  [ .[] | select(.path == $path) ] | length;

def rows_with_metadata($records; $names):
  [
    range(0; 12) as $index
    | $records[$index] as $record
    | (filename_metadata($names[$index]) + {sequence: ($index + 1)}) as $metadata
    | expected_official_metadata[$index] as $expected
    | if $metadata != $expected then
        error("official filename metadata가 기대값과 다릅니다: \($names[$index])")
      elif $record.path != $metadata.path then
        error("official filename strategy와 JSON path가 다릅니다: \($metadata.basename)")
      else
        {
          sequence: $metadata.sequence,
          round: $metadata.round,
          position: $metadata.position,
          basename: $metadata.basename,
          path: $record.path,
          elapsedNanos: $record.elapsedNanos,
          elapsedSeconds: ($record.elapsedNanos / 1000000000),
          elapsedMillis: ($record.elapsedNanos / 1000000),
          rowsPerSecond: ($record.inputCount * 1000000000 / $record.elapsedNanos),
          valid: $record.valid
        }
      end
  ];

def require_gate($expectedCount; $fileNames):
  . as $records
  | require_file_name_gate($fileNames) as $names
  | if ($records | length) != 12 then
      error("official JSON 파일 수가 정확히 12개가 아닙니다: \($records | length)")
    elif any($records[]; (artifact_record_valid($expectedCount) | not)) then
      error("official JSON gate를 통과하지 못한 파일이 있습니다.")
    else
      rows_with_metadata($records; $names) as $rows
      | if ($rows | path_count("jpa")) != 6 then
          error("JPA official valid result count가 6개가 아닙니다: \($rows | path_count("jpa"))")
        elif ($rows | path_count("jdbc")) != 6 then
          error("JDBC official valid result count가 6개가 아닙니다: \($rows | path_count("jdbc"))")
        else
          $rows
        end
    end;

def path_rows($path):
  [
    .[] | select(.path == $path)
  ];

def metric_values($path; $metric):
  [ path_rows($path)[] | .[$metric] ];

def median($values):
  ($values | sort) as $sorted
  | ($sorted | length) as $count
  | if $count == 0 then
      null
    elif ($count % 2) == 1 then
      $sorted[($count / 2 | floor)]
    else
      (($sorted[($count / 2) - 1] + $sorted[($count / 2)]) / 2)
    end;

def pow10($digits):
  reduce range(0; $digits) as $i (1; . * 10);

def fixed($digits):
  if . == null then
    "null"
  else
    . as $number
    | (if $number < 0 then -1 else 1 end) as $sign
    | ($number * $sign) as $absolute
    | pow10($digits) as $scale
    | (($absolute * $scale) + 0.5 | floor) as $scaled
    | ($scaled / $scale | floor) as $integer
    | ($scaled - ($integer * $scale)) as $fraction
    | ($fraction | tostring) as $fractionText
    | (
        if $digits == 0 then
          ""
        else
          (reduce range(($fractionText | length); $digits) as $i (""; . + "0") + $fractionText)
        end
      ) as $paddedFraction
    | (if $sign < 0 then "-" else "" end)
      + ($integer | tostring)
      + (if $digits == 0 then "" else "." + $paddedFraction end)
  end;

def metric_digits($metric):
  if $metric == "elapsedSeconds" then 9
  elif $metric == "elapsedMillis" then 3
  elif $metric == "elapsedNanos" then 3
  elif $metric == "rowsPerSecond" then 2
  else 3
  end;

def metric_stats($path; $metric):
  metric_values($path; $metric) as $values
  | ($values | length) as $n
  | ($values | add / $n) as $mean
  | (
      if $n > 1 then
        (($values | map((. - $mean) * (. - $mean)) | add) / ($n - 1) | sqrt)
      else
        0
      end
    ) as $stddev
  | {
      path: $path,
      metric: $metric,
      min: ($values | min),
      max: ($values | max),
      mean: $mean,
      median: median($values),
      sampleStddev: $stddev,
      cv: (if $mean == 0 then null else ($stddev / $mean * 100) end)
    };

def stats_line($stats):
  ($stats.metric | metric_digits(.)) as $digits
  | "| \($stats.path) | \($stats.metric) | \($stats.min | fixed($digits)) | \($stats.max | fixed($digits)) | \($stats.mean | fixed($digits)) | \($stats.median | fixed($digits)) | \($stats.sampleStddev | fixed($digits)) | \(if $stats.cv == null then "null" else (($stats.cv | fixed(2)) + "%") end) |";

def human_elapsed:
  if . < 1000000000 then
    ((. / 1000000) | fixed(3)) + "ms"
  elif . < 60000000000 then
    ((. / 1000000000) | fixed(3)) + "s"
  else
    (. / 60000000000 | floor) as $minutes
    | (. - ($minutes * 60000000000)) as $remainingNanos
    | "\($minutes)m \(($remainingNanos / 1000000000) | fixed(3))s"
  end;

def run_line:
  "| \(.sequence) | \(.round) | \(.path) | \(.elapsedNanos | human_elapsed) | \(.elapsedSeconds | fixed(9)) | \(.elapsedMillis | fixed(3)) | \(.elapsedNanos | fixed(0)) | \(.rowsPerSecond | fixed(2)) | \(.valid) |";

def median_unit_line($path):
  (metric_stats($path; "elapsedNanos")) as $stats
  | "| \($path) | \(($stats.median / 1000000000) | fixed(9)) | \(($stats.median / 1000000) | fixed(3)) | \($stats.median | fixed(3)) |";

require_gate($expectedCount; $officialFileNames) as $records
| ($records | metric_stats("jpa"; "elapsedNanos")) as $jpaNanosStats
| ($records | metric_stats("jdbc"; "elapsedNanos")) as $jdbcNanosStats
| ($jpaNanosStats.median) as $jpaMedianNanos
| ($jdbcNanosStats.median) as $jdbcMedianNanos
| (if $jdbcMedianNanos == 0 then null else ($jpaMedianNanos / $jdbcMedianNanos) end) as $medianSpeedup
| (if $jpaMedianNanos == 0 then null else ((1 - ($jdbcMedianNanos / $jpaMedianNanos)) * 100) end) as $medianReduction
| (if $jdbcNanosStats.mean == 0 then null else ($jpaNanosStats.mean / $jdbcNanosStats.mean) end) as $meanSpeedup
| [
    "# EXP-001 Summary",
    "",
    "Warm-up 결과는 제외하고 official valid JSON만 사용했다.",
    "",
    "## Run Metadata",
    "",
    "- official JSON: 12",
    "- JPA valid JSON: 6",
    "- JDBC valid JSON: 6",
    "- inputCount/savedCount/rowCount: \($expectedCount)",
    "- result schema: legacy와 v2를 파일별로 검증",
    "- elapsed source of truth: elapsedNanos",
    "- checksum: lowercase SHA-256 형식과 equality 확인",
    "- warm-up: excluded",
    "- p95: excluded",
    "",
    "## Official Run Table",
    "",
    "| Sequence | Round | Strategy | Elapsed | Seconds | Milliseconds | Nanoseconds | Rows/s | Valid |",
    "|---:|---:|---|---:|---:|---:|---:|---:|---|",
    ($records[] | run_line),
    "",
    "## Statistical Summary",
    "",
    "| Strategy | Metric | Min | Max | Mean | Median | Sample Stddev | CV |",
    "|---|---|---:|---:|---:|---:|---:|---:|",
    ($records | metric_stats("jpa"; "elapsedSeconds") | stats_line(.)),
    ($records | metric_stats("jdbc"; "elapsedSeconds") | stats_line(.)),
    ($records | metric_stats("jpa"; "elapsedMillis") | stats_line(.)),
    ($records | metric_stats("jdbc"; "elapsedMillis") | stats_line(.)),
    ($records | metric_stats("jpa"; "elapsedNanos") | stats_line(.)),
    ($records | metric_stats("jdbc"; "elapsedNanos") | stats_line(.)),
    "",
    "## Median Unit Overview",
    "",
    "| Strategy | Seconds | Milliseconds | Nanoseconds |",
    "|---|---:|---:|---:|",
    ($records | median_unit_line("jpa")),
    ($records | median_unit_line("jdbc")),
    "",
    "## Throughput Summary",
    "",
    "| Strategy | Metric | Min | Max | Mean | Median | Sample Stddev | CV |",
    "|---|---|---:|---:|---:|---:|---:|---:|",
    ($records | metric_stats("jpa"; "rowsPerSecond") | stats_line(.)),
    ($records | metric_stats("jdbc"; "rowsPerSecond") | stats_line(.)),
    "",
    "## Derived Comparison",
    "",
    "- Median speedup: \(if $medianSpeedup == null then "null" else ($medianSpeedup | fixed(6)) end)",
    "- JDBC median elapsed reduction: \(if $medianReduction == null then "null" else (($medianReduction | fixed(2)) + "%") end)",
    "- Mean speedup: \(if $meanSpeedup == null then "null" else ($meanSpeedup | fixed(6)) end)",
    "",
    "## Interpretation Boundary",
    "",
    "이 summary는 official JSON 12개만 집계한다. Warm-up, p95, profiler output, 다른 OS/JVM/DB/hardware 일반화는 포함하지 않는다."
  ]
| .[]
