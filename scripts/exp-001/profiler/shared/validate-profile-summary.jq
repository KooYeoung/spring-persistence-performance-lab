def fail($message):
  error($message);

def exact_keys($allowed):
  type == "object" and ((keys_unsorted | sort) == ($allowed | sort));

def nonempty_string:
  type == "string" and length > 0;

def sha256_checksum:
  type == "string" and test("^[0-9a-f]{64}$");

def integer:
  type == "number" and floor == .;

def positive_integer:
  integer and . > 0;

def nonnegative_number:
  type == "number" and . >= 0;

def event_allowed:
  . == "cpu" or . == "ctimer" or . == "alloc";

def strategy_allowed:
  . == "jpa" or . == "jdbc";

def interval_allowed_for($event):
  if $event == "alloc" then
    . == "512k"
  else
    . == "10ms"
  end;

def basename_safe:
  type == "string"
  and length > 0
  and (test("[/\\\\]") | not)
  and (contains("..") | not)
  and (test("^[A-Za-z]:") | not)
  and (test("pid|processid"; "i") | not);

def sensitive_key:
  type == "string"
  and (
    ascii_downcase as $key
    | [
        "username",
        "hostname",
        "pid",
        "processid",
        "absolutepath",
        "commandline",
        "fullcommandline",
        "workingdirectory",
        "homedirectory",
        "environment",
        "env",
        "password",
        "secret",
        "token",
        "apikey",
        "credential"
      ]
      | index($key) != null
  );

def sensitive_string:
  type == "string"
  and (
    test("^[A-Za-z]:[\\\\/]")
    or test("^\\\\\\\\")
    or test("C:\\\\Users\\\\"; "i")
    or test("^/(home|Users|tmp|var|etc|opt|root|mnt|Volumes)(/|$)")
    or (explode | any(. < 32))
  );

def no_sensitive_keys:
  [ paths
    | select(length > 0)
    | .[-1]
    | select(sensitive_key)
  ]
  | length == 0;

def no_sensitive_values:
  [ paths(scalars) as $path
    | getpath($path)
    | select(sensitive_string)
  ]
  | length == 0;

def top_named_valid:
  exact_keys(["name", "value"])
  and (.name | nonempty_string)
  and (.value | nonnegative_number);

def top_stack_valid:
  exact_keys(["stack", "value"])
  and (.stack | nonempty_string)
  and (.stack | sensitive_string | not)
  and (.value | nonnegative_number);

def workload_gate_valid:
  exact_keys(["valid", "inputCount", "savedCount", "rowCount"])
  and .valid == true
  and (.inputCount | positive_integer)
  and (.savedCount | positive_integer)
  and (.rowCount | positive_integer);

def manifest_entry_valid($profile):
  exact_keys(["fileName", "size", "sha256", "event", "strategy", "chunkCount"])
  and (.fileName | basename_safe)
  and (.size | positive_integer)
  and (.sha256 | sha256_checksum)
  and (.event == $profile.event)
  and (.strategy == $profile.strategy)
  and (.chunkCount == $profile.chunkCount);

def sample_threshold_valid($profile):
  exact_keys(["hardMinimum", "recommendedMinimum", "status"])
  and (.hardMinimum | positive_integer)
  and (.recommendedMinimum | positive_integer)
  and .recommendedMinimum >= .hardMinimum
  and ($profile.sampleCount >= .hardMinimum)
  and (
    if $profile.sampleCount >= .recommendedMinimum then
      .status == "recommended-pass"
    else
      .status == "hard-pass"
    end
  );

def profile_valid:
  . as $profile
  | exact_keys([
      "event",
      "cpuEngine",
      "strategy",
      "interval",
      "repetitions",
      "totalRows",
      "chunkCount",
      "validChunkCount",
      "sampleCount",
      "sampledValue",
      "normalizationUnit",
      "topPackages",
      "topClasses",
      "topMethods",
      "topStacks",
      "workloadGate",
      "artifactManifest",
      "sampleThreshold",
      "success"
    ])
  and (.event | event_allowed)
  and (.strategy | strategy_allowed)
  and ($profile.interval | interval_allowed_for($profile.event))
  and (.repetitions | positive_integer)
  and (.totalRows | positive_integer)
  and (.chunkCount | positive_integer)
  and (.validChunkCount | positive_integer)
  and (.validChunkCount == .chunkCount)
  and (.sampleCount | nonnegative_number)
  and (.sampledValue | nonnegative_number)
  and ((.normalizationUnit == "samples") or (.normalizationUnit == "bytes"))
  and (if .event == "alloc" then (.cpuEngine == null and .normalizationUnit == "bytes") else ((.cpuEngine == "cpu" or .cpuEngine == "ctimer") and .normalizationUnit == "samples") end)
  and (.topPackages | type == "array" and length > 0)
  and (all(.topPackages[]; top_named_valid))
  and (.topClasses | type == "array" and length > 0)
  and (all(.topClasses[]; top_named_valid))
  and (.topMethods | type == "array" and length > 0)
  and (all(.topMethods[]; top_named_valid))
  and (.topStacks | type == "array" and length > 0)
  and (all(.topStacks[]; top_stack_valid))
  and (.workloadGate | workload_gate_valid)
  and (.artifactManifest | type == "array" and length > 0)
  and (all(.artifactManifest[]; manifest_entry_valid($profile)))
  and (.sampleThreshold | sample_threshold_valid($profile))
  and (.success == true);

def profile_logical_key:
  if .event == "alloc" then
    "alloc:\(.strategy)"
  elif .event == "cpu" or .event == "ctimer" then
    "cpu:\(.strategy)"
  else
    "unknown:\(.strategy)"
  end;

def duplicate_profile_keys:
  [ .profiles[] | profile_logical_key ]
  | sort
  | group_by(.)
  | map(select(length > 1) | .[0]);

def profile_set_valid:
  ([ .profiles[] | profile_logical_key ] | sort) == ["alloc:jdbc", "alloc:jpa", "cpu:jdbc", "cpu:jpa"];

def cpu_engines:
  [ .profiles[] | select(.event == "cpu" or .event == "ctimer") | .cpuEngine ];

def runtime_valid:
  exact_keys(["primaryRuntime", "securityLevel", "nativeWindowsSupported"])
  and .primaryRuntime == "docker-linux-x64"
  and (.securityLevel | integer)
  and (.securityLevel >= 0 and .securityLevel <= 2)
  and .nativeWindowsSupported == false;

def profiler_valid:
  exact_keys(["name", "version", "platform", "assetSha256"])
  and .name == "async-profiler"
  and .version == "4.5"
  and .platform == "linux-x64"
  and (.assetSha256 | sha256_checksum);

def cross_profile_validation_valid:
  exact_keys(["cpuEngineConsistent", "strategyChunkCountsValid", "workloadGatesValid"])
  and .cpuEngineConsistent == true
  and .strategyChunkCountsValid == true
  and .workloadGatesValid == true;

def require_valid_summary:
  . as $summary
  | if ($summary | exact_keys([
      "profileFormatVersion",
      "experiment",
      "phase",
      "profileRunId",
      "sourceRevision",
      "harnessRevision",
      "runtime",
      "profiler",
      "profiles",
      "crossProfileValidation",
      "success"
    ]) | not) then
      fail("summary root schema is invalid")
    elif ($summary | no_sensitive_keys | not) then
      fail("summary contains a sensitive key")
    elif ($summary | no_sensitive_values | not) then
      fail("summary contains a sensitive value")
    elif ($summary.profileFormatVersion | integer | not) or $summary.profileFormatVersion != 1 then
      fail("profileFormatVersion is invalid")
    elif $summary.experiment != "EXP-001" then
      fail("experiment is invalid")
    elif ($summary.phase | nonempty_string | not) then
      fail("phase is empty")
    elif ($summary.profileRunId | test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{7,12}$") | not) then
      fail("profileRunId is invalid")
    elif ($summary.sourceRevision | test("^[0-9a-f]{7,40}$") | not) then
      fail("sourceRevision is invalid")
    elif ($summary.harnessRevision | test("^[0-9a-f]{7,40}$") | not) then
      fail("harnessRevision is invalid")
    elif ($summary.runtime | runtime_valid | not) then
      fail("runtime metadata is invalid")
    elif ($summary.profiler | profiler_valid | not) then
      fail("profiler metadata is invalid")
    elif ($summary.profiles | type) != "array" or ($summary.profiles | length) != 4 then
      fail("profile entry count is invalid")
    elif (profile_set_valid | not) then
      fail("profile set is incomplete")
    elif (duplicate_profile_keys | length) != 0 then
      fail("duplicate profile entry: \((duplicate_profile_keys) | join(", "))")
    elif (all($summary.profiles[]; profile_valid) | not) then
      fail("profile entry schema or threshold gate failed")
    elif ((cpu_engines | unique | length) != 1) then
      fail("CPU profile engine is inconsistent")
    elif ($summary.crossProfileValidation | cross_profile_validation_valid | not) then
      fail("crossProfileValidation gate is invalid")
    elif $summary.success != true then
      fail("summary success is not true")
    else
      true
    end;

require_valid_summary
