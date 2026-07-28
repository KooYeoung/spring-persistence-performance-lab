def fail($message):
  error($message);

def exact_keys($allowed):
  type == "object" and ((keys_unsorted | sort) == ($allowed | sort));

def nonempty_string:
  type == "string" and length > 0;

def positive_integer:
  type == "number" and floor == . and . > 0;

def sha256_checksum:
  type == "string" and test("^[0-9a-f]{64}$");

def basename_safe:
  type == "string"
  and length > 0
  and (test("[/\\\\]") | not)
  and (contains("..") | not)
  and (test("^[A-Za-z]:") | not);

def event_allowed:
  . == "cpu" or . == "ctimer" or . == "alloc";

def strategy_allowed:
  . == "jpa" or . == "jdbc";

def counter_kind_allowed:
  . == "cpuSamples" or . == "allocationSamples" or . == "allocationBytes";

def counter_kind_matches_event($event):
  if $event == "alloc" then
    . == "allocationSamples" or . == "allocationBytes"
  else
    . == "cpuSamples"
  end;

def interval_matches_event($event):
  if $event == "alloc" then
    . == "512k"
  else
    . == "10ms"
  end;

def manifest_root_valid:
  . as $root
  | exact_keys([
    "aggregationFormatVersion",
    "profileId",
    "event",
    "cpuEngine",
    "strategy",
    "interval",
    "counterKind",
    "repetitions",
    "rowsPerInvocation",
    "totalRows",
    "expectedChunkCount",
    "chunks"
  ])
  and .aggregationFormatVersion == 1
  and (.profileId | nonempty_string)
  and (.event | event_allowed)
  and (if .event == "alloc" then .cpuEngine == null else (.cpuEngine == "cpu" or .cpuEngine == "ctimer") end)
  and (.strategy | strategy_allowed)
  and ($root.interval | interval_matches_event($root.event))
  and (.counterKind | counter_kind_allowed)
  and ($root.counterKind | counter_kind_matches_event($root.event))
  and (.repetitions | positive_integer)
  and (.rowsPerInvocation | positive_integer)
  and (.totalRows | positive_integer)
  and (.expectedChunkCount | positive_integer)
  and (.chunks | type == "array");

def chunk_valid($root):
  exact_keys([
    "sequence",
    "filename",
    "event",
    "strategy",
    "counterKind",
    "rows",
    "workloadValid",
    "sourceArtifactSha256",
    "collapsedContent"
  ])
  and (.sequence | positive_integer)
  and (.filename | basename_safe)
  and .event == $root.event
  and .strategy == $root.strategy
  and .counterKind == $root.counterKind
  and .rows == $root.rowsPerInvocation
  and .workloadValid == true
  and (.sourceArtifactSha256 | sha256_checksum)
  and (.collapsedContent | type == "string");

def duplicate_values($items):
  $items
  | sort
  | group_by(.)
  | map(select(length > 1) | .[0]);

def expected_sequence($n):
  [range(1; $n + 1)];

def validate_manifest:
  . as $root
  | if (manifest_root_valid | not) then
      fail("aggregation manifest schema is invalid")
    elif ($root.chunks | length) != $root.expectedChunkCount then
      fail("chunk count does not match expectedChunkCount")
    elif $root.expectedChunkCount != $root.repetitions then
      fail("expectedChunkCount does not match repetitions")
    elif ($root.totalRows != ($root.rowsPerInvocation * $root.expectedChunkCount)) then
      fail("totalRows does not match chunk rows")
    elif (all($root.chunks[]; chunk_valid($root)) | not) then
      fail("chunk schema or identity is invalid")
    elif ((duplicate_values([$root.chunks[].sequence]) | length) != 0) then
      fail("duplicate chunk sequence")
    elif (([$root.chunks[].sequence] | sort) != expected_sequence($root.expectedChunkCount)) then
      fail("missing or unexpected chunk sequence")
    elif ((duplicate_values([$root.chunks[].filename]) | length) != 0) then
      fail("duplicate chunk filename")
    else
      $root
    end;

def nonempty_lines($text):
  $text
  | split("\n")
  | map(select(length > 0));

def parse_collapsed_line:
  if (test("^\\S(?:.*\\S)?\\s+[0-9]+(?:\\.[0-9]+)?$") | not) then
    fail("collapsed line is malformed")
  else
    capture("^(?<stack>\\S(?:.*\\S)?)\\s+(?<value>[0-9]+(?:\\.[0-9]+)?)$")
  end
  | {
      stack: .stack,
      value: (.value | tonumber)
    }
  | if (.value <= 0) then
      fail("collapsed counter must be positive")
    else
      .
    end;

def aggregate_by_stack:
  sort_by(.stack)
  | group_by(.stack)
  | map({
      stack: .[0].stack,
      value: (map(.value) | add)
    })
  | sort_by(-.value, .stack);

def stack_frames:
  .stack | split(";") | map(select(length > 0));

def frame_category($frame):
  if $frame | test("com\\.example\\.persistencebenchmark") then
    "application"
  elif $frame | test("org\\.hibernate|jakarta\\.persistence|javax\\.persistence") then
    "hibernateJpa"
  elif $frame | test("org\\.postgresql|java\\.sql|javax\\.sql|com\\.zaxxer\\.hikari") then
    "jdbcDriver"
  elif $frame | test("(^|[; ])(java|jdk|sun)\\.|libjvm|GC|G1|VMThread|ObjectSynchronizer") then
    "jvmGcNative"
  else
    "other"
  end;

def aggregate_named($items):
  $items
  | sort_by(.name)
  | group_by(.name)
  | map({
      name: .[0].name,
      value: (map(.value) | add)
    })
  | sort_by(-.value, .name);

def package_name($frame):
  ($frame | split(".")) as $parts
  | if ($parts | length) > 2 then
      ($parts[0:(($parts | length) - 2)] | join("."))
    elif ($parts | length) > 1 then
      $parts[0]
    else
      "(native)"
    end;

def class_name($frame):
  ($frame | split("(")[0] | split(".")) as $parts
  | if ($parts | length) > 1 then
      ($parts[0:(($parts | length) - 1)] | join("."))
    else
      $frame
    end;

def share_rows($rows; $total):
  $rows
  | map(. + {share: (if $total == 0 then 0 else (.value / $total) end)});

def parsed_rows:
  [ .chunks[]
    | .collapsedContent as $content
    | nonempty_lines($content)[]
    | parse_collapsed_line
  ];

def collapsed_summary($root; $rows):
  ($rows | map(.value) | add // 0) as $total
  | {
      profileId: $root.profileId,
      event: $root.event,
      cpuEngine: (if $root.event == "alloc" then null else $root.cpuEngine end),
      strategy: $root.strategy,
      interval: $root.interval,
      repetitions: $root.repetitions,
      totalRows: $root.totalRows,
      chunkCount: $root.expectedChunkCount,
      validChunkCount: $root.expectedChunkCount,
      sampleCount: (if $root.counterKind == "allocationBytes" then ($rows | length) else $total end),
      sampledValue: $total,
      normalizationUnit: (if $root.counterKind == "allocationBytes" then "bytes" else "samples" end),
      normalizedSampledValuePer50000Rows: ($total * 50000 / $root.totalRows),
      categoryShare: (
        $rows
        | map(. as $row | (stack_frames | map(frame_category(.)) | unique)[] as $category | {name: $category, value: $row.value})
        | aggregate_named(.)
        | share_rows(.; $total)
      ),
      topPackages: (
        $rows
        | map(. as $row | stack_frames[] as $frame | {name: package_name($frame), value: $row.value})
        | aggregate_named(.)
        | .[0:10]
      ),
      topClasses: (
        $rows
        | map(. as $row | stack_frames[] as $frame | {name: class_name($frame), value: $row.value})
        | aggregate_named(.)
        | .[0:10]
      ),
      topMethods: (
        $rows
        | map(. as $row | stack_frames[] as $frame | {name: $frame, value: $row.value})
        | aggregate_named(.)
        | .[0:10]
      ),
      topStacks: ($rows[0:10])
    };

validate_manifest as $root
| ($root | parsed_rows | aggregate_by_stack) as $rows
| if ($rows | length) == 0 then
    fail("collapsed content is empty")
  else
    collapsed_summary($root; $rows)
  end
