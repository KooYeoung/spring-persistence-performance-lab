def sha256_checksum:
  type == "string" and test("^[0-9a-f]{64}$");

def valid_record($expectedCount):
  type == "object"
  and (.valid == true)
  and ((.path == "jpa") or (.path == "jdbc"))
  and ((.inputCount | type == "number") and (.inputCount == $expectedCount))
  and ((.savedCount | type == "number") and (.savedCount == $expectedCount))
  and ((.rowCount | type == "number") and (.rowCount == $expectedCount))
  and ((.distinctBusinessKeyCount | type == "number") and (.distinctBusinessKeyCount == $expectedCount))
  and ((.elapsedNanos | type == "number") and (.elapsedNanos > 0))
  and ((.missingKeyCount | type == "number") and (.missingKeyCount == 0))
  and ((.unexpectedKeyCount | type == "number") and (.unexpectedKeyCount == 0))
  and ((.duplicateKeyCount | type == "number") and (.duplicateKeyCount == 0))
  and (.expectedChecksum | sha256_checksum)
  and (.actualChecksum | sha256_checksum)
  and (.expectedChecksum == .actualChecksum);

def path_count($path):
  [ .[] | select(.path == $path) ] | length;

def require_gate($expectedCount):
  if length != 12 then
    error("official JSON 파일 수가 정확히 12개가 아닙니다: \(length)")
  elif any(.[]; (valid_record($expectedCount) | not)) then
    error("official JSON gate를 통과하지 못한 파일이 있습니다.")
  elif path_count("jpa") != 6 then
    error("JPA official valid result count가 6개가 아닙니다: \(path_count("jpa"))")
  elif path_count("jdbc") != 6 then
    error("JDBC official valid result count가 6개가 아닙니다: \(path_count("jdbc"))")
  else
    .
  end;

def rows($path):
  [
    .[] | select(.path == $path) | {
      elapsedNanos: .elapsedNanos,
      elapsedMillis: (.elapsedNanos / 1000000),
      rowsPerSecond: (.inputCount * 1000000000 / .elapsedNanos)
    }
  ];

def metric_values($path; $metric):
  [ rows($path)[] | .[$metric] ];

def median($values):
  ($values | sort) as $sorted
  | (($sorted[2] + $sorted[3]) / 2);

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
  if $metric == "rowsPerSecond" then 2 else 3 end;

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

def metric_line($stats):
  ($stats.metric | metric_digits(.)) as $digits
  | "| \($stats.path) | \($stats.metric) | \($stats.min | fixed($digits)) | \($stats.max | fixed($digits)) | \($stats.mean | fixed($digits)) | \($stats.median | fixed($digits)) | \($stats.sampleStddev | fixed($digits)) | \(if $stats.cv == null then "null" else (($stats.cv | fixed(2)) + "%") end) |";

require_gate($expectedCount) as $records
| ($records | metric_values("jpa"; "elapsedNanos") | median(.)) as $jpaMedianNanos
| ($records | metric_values("jdbc"; "elapsedNanos") | median(.)) as $jdbcMedianNanos
| (if $jpaMedianNanos == 0 then null else (($jpaMedianNanos - $jdbcMedianNanos) / $jpaMedianNanos * 100) end) as $timeReduction
| (if $jdbcMedianNanos == 0 then null else ($jpaMedianNanos / $jdbcMedianNanos) end) as $speedup
| [
    "# EXP-001 Summary",
    "",
    "Warm-up 결과는 제외하고 official valid JSON만 사용했다.",
    "",
    "## Input Gate",
    "",
    "- official JSON: 12",
    "- JPA valid JSON: 6",
    "- JDBC valid JSON: 6",
    "- inputCount/savedCount/rowCount: \($expectedCount)",
    "- checksum: lowercase SHA-256 형식과 equality 확인",
    "",
    "## Metrics",
    "",
    "| path | metric | min | max | mean | median | sample stddev | CV |",
    "|---|---:|---:|---:|---:|---:|---:|---:|",
    ($records | metric_stats("jpa"; "elapsedNanos") | metric_line(.)),
    ($records | metric_stats("jdbc"; "elapsedNanos") | metric_line(.)),
    ($records | metric_stats("jpa"; "elapsedMillis") | metric_line(.)),
    ($records | metric_stats("jdbc"; "elapsedMillis") | metric_line(.)),
    ($records | metric_stats("jpa"; "rowsPerSecond") | metric_line(.)),
    ($records | metric_stats("jdbc"; "rowsPerSecond") | metric_line(.)),
    "",
    "## Comparison",
    "",
    "- JDBC median elapsed 기준 time reduction: \(if $timeReduction == null then "null" else (($timeReduction | fixed(2)) + "%") end)",
    "- JDBC median elapsed 기준 speedup: \(if $speedup == null then "null" else ($speedup | fixed(6)) end)"
  ]
| .[]
