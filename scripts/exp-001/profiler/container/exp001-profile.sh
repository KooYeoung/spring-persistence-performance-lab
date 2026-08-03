#!/usr/bin/env bash
set -Eeuo pipefail

ASPROF_HOME="${EXP001_ASPROF_HOME:-/opt/async-profiler}"
ASPROF_BIN="$ASPROF_HOME/bin/asprof"
JFRCONV_BIN="$ASPROF_HOME/bin/jfrconv"
ASPROF_LIB="$ASPROF_HOME/lib/libasyncProfiler.so"
ASPROF_EXPECTED_VERSION="4.5"
JFR_BIN="${EXP001_JFR_BIN:-jfr}"
JAVA_BIN="${EXP001_JAVA_BIN:-java}"
CURL_BIN="${EXP001_CURL_BIN:-curl}"
APP_JAR="${EXP001_APP_JAR:-/app/app.jar}"
APP_PROFILE="${SPRING_PROFILES_ACTIVE:-exp001}"
APP_URL="${EXP001_APP_URL:-http://127.0.0.1:8080}"
ARTIFACT_ROOT="${EXP001_ARTIFACT_ROOT:-/artifacts/exp-001/profiling}"
DEFAULT_COUNT="${EXP001_ROWS_PER_INVOCATION:-50000}"
PROC_ROOT="${EXP001_PROC_ROOT:-/proc}"
JCMD_LIST_FILE="${EXP001_JCMD_LIST_FILE:-}"
SMOKE_PROTOCOL_VERSION="exp001-smoke-v1"
SMOKE_MARKER_FORMAT_VERSION=2
CPU_WORKLOAD_VERSION="cpu-v1"
ALLOCATION_WORKLOAD_VERSION="allocation-v1"
SMOKE_READY_STATUS="READY"
SMOKE_READY_PHASE="EXP001_SMOKE"
SMOKE_ENGINE_VERIFICATION_PERF_EVENTS="jfr-active-setting-engine:perf_events"
SMOKE_ENGINE_VERIFICATION_CTIMER="jfr-active-setting-engine:ctimer"
SMOKE_RESPONSE_MAX_BYTES=4096
SMOKE_HTTP_CONNECT_TIMEOUT_SECONDS=2
SMOKE_READY_TIMEOUT_SECONDS=90
SMOKE_READY_POLL_SECONDS=1
SMOKE_CPU_MIN_DURATION_MILLIS=2500
SMOKE_CPU_HARD_SAMPLES=50
SMOKE_CPU_RECOMMENDED_SAMPLES=100
SMOKE_ALLOCATION_BYTES=67108864
SMOKE_ALLOCATION_CHUNK_BYTES=1048576
SMOKE_ALLOCATION_CHUNKS=64
SMOKE_ALLOCATION_HARD_SAMPLES=8
SMOKE_ALLOCATION_RECOMMENDED_SAMPLES=16
SMOKE_ALLOCATION_HARD_BYTES=4194304
SMOKE_ALLOCATION_RECOMMENDED_BYTES=8388608
SMOKE_LAST_ACTUAL_ENGINE=""
SMOKE_LAST_CPU_SAMPLE_COUNT=""
SMOKE_LAST_ALLOCATION_SAMPLE_COUNT=""
SMOKE_LAST_ALLOCATION_SAMPLED_BYTES=""

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >&2
  exit 1
}

show_help() {
  cat <<'EOF'
EXP-001 async-profiler container harness

Actions:
  run-app       run the EXP-001 Spring Boot application.
  require-tool  verify the mounted async-profiler tool.
  smoke         verify tiny cpu/ctimer/alloc profiler sessions.
  call          call one jpa/jdbc endpoint without profiler.
  record-chunk  run one profiler start/endpoint/stop/convert chunk.
  fixture-*     run parser/static fixtures without Docker or profiler.
EOF
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || die "Required file is missing: $file"
}

require_executable() {
  local file="$1"
  [[ -x "$file" ]] || die "Executable file is missing: $file"
}

file_has_hex_byte() {
  local file="$1"
  local byte="$2"
  local -a pipeline_status
  local od_status
  local grep_status

  [[ "$byte" =~ ^[[:xdigit:]][[:xdigit:]]$ ]] || return 2
  byte="${byte,,}"

  if LC_ALL=C od -An -tx1 -v "$file" 2>/dev/null \
    | LC_ALL=C grep -E "(^|[[:space:]])${byte}([[:space:]]|$)" >/dev/null; then
    pipeline_status=("${PIPESTATUS[@]}")
  else
    pipeline_status=("${PIPESTATUS[@]}")
  fi

  od_status="${pipeline_status[0]}"
  grep_status="${pipeline_status[1]}"
  [[ "$od_status" -eq 0 ]] || return 2

  case "$grep_status" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

require_absent_hex_byte() {
  local file="$1"
  local byte="$2"
  local label="$3"
  local scan_status

  file_has_hex_byte "$file" "$byte"
  scan_status=$?
  case "$scan_status" in
    0)
      printf 'async-profiler version stdout contains forbidden %s byte\n' "$label" >&2
      return 1
      ;;
    1)
      return 0
      ;;
    *)
      printf 'async-profiler version stdout %s byte scan failed\n' "$label" >&2
      return 1
      ;;
  esac
}

validate_asprof_version_stdout() {
  local stdout_file="$1"
  local expected_version="$2"
  local line_feed_count
  local stdout
  local product
  local product_lower
  local version
  local suffix

  require_absent_hex_byte "$stdout_file" 00 NUL || return 1
  require_absent_hex_byte "$stdout_file" 1b ANSI || return 1

  line_feed_count="$(LC_ALL=C tr -cd '\n' <"$stdout_file" | wc -c | tr -d '[:space:]')"
  [[ "$line_feed_count" -le 1 ]] || return 1

  stdout="$(cat "$stdout_file")"
  stdout="${stdout%$'\r'}"
  [[ "$stdout" != *$'\r'* ]] || return 1
  [[ "$stdout" != *$'\n'* ]] || return 1

  if [[ ! "$stdout" =~ ^[[:blank:]]*([^[:blank:]]+)[[:blank:]]+([0-9]+[.][0-9]+([.][0-9]+)?)([[:blank:]]+.*)?[[:blank:]]*$ ]]; then
    return 1
  fi

  product="${BASH_REMATCH[1]}"
  product_lower="${product,,}"
  version="${BASH_REMATCH[2]}"
  suffix="${BASH_REMATCH[4]:-}"

  [[ "$product_lower" == "async-profiler" ]] || return 1
  [[ "$version" == "$expected_version" ]] || return 1

  if [[ -n "$suffix" && "$suffix" =~ (^|[^0-9.])([0-9]+[.][0-9]+([.][0-9]+)?)([^0-9.]|$) ]]; then
    return 1
  fi
}

require_tool() {
  require_executable "$ASPROF_BIN"
  require_executable "$JFRCONV_BIN"
  require_file "$ASPROF_LIB"
  command -v "$JFR_BIN" >/dev/null 2>&1 || die "JDK jfr tool is missing"
  command -v "$JAVA_BIN" >/dev/null 2>&1 || die "JDK java tool is missing"

  local stdout_file
  local stderr_file
  local asprof_exit
  stdout_file="$(mktemp -t exp001-asprof-version-stdout.XXXXXX)"
  stderr_file="$(mktemp -t exp001-asprof-version-stderr.XXXXXX)"

  if "$ASPROF_BIN" --version >"$stdout_file" 2>"$stderr_file"; then
    asprof_exit=0
  else
    asprof_exit=$?
  fi

  if [[ "$asprof_exit" -ne 0 ]] \
    || ! validate_asprof_version_stdout "$stdout_file" "$ASPROF_EXPECTED_VERSION"; then
    rm -f "$stdout_file" "$stderr_file"
    die "async-profiler version does not match the lock"
  fi

  rm -f "$stdout_file" "$stderr_file"
  log "async-profiler ${ASPROF_EXPECTED_VERSION} verified"
}

safe_name() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._=-]+$ ]] || die "Unsafe artifact name value"
}

validate_basename() {
  local value="$1"
  [[ -n "$value" ]] || die "Empty basename is not allowed"
  [[ "$value" != *'/'* && "$value" != *'\'* && "$value" != *'..'* && ! "$value" =~ ^[A-Za-z]: ]] \
    || die "Path traversal in basename is not allowed"
}

validate_output_path() {
  local output="$1"
  [[ -n "$output" ]] || die "output path is required"
  case "$output" in
    "$ARTIFACT_ROOT"/*) ;;
    *) die "output path must stay under artifact root" ;;
  esac
  validate_basename "$(basename "$output")"
  local parent
  parent="$(dirname "$output")"
  ensure_dir "$parent"
  local parent_physical
  local root_physical
  parent_physical="$(cd "$parent" && pwd -P)"
  root_physical="$(cd "$ARTIFACT_ROOT" && pwd -P)"
  case "$parent_physical" in
    "$root_physical"|"$root_physical"/*) ;;
    *) die "output path escapes artifact root" ;;
  esac
}

ensure_dir() {
  local dir="$1"
  mkdir -p "$dir"
  [[ -d "$dir" ]] || die "Unable to create directory"
}

promote_no_clobber() {
  promote_no_clobber_maybe "$@" || die "Unable to promote temporary file"
}

promote_no_clobber_maybe() {
  local temp="$1"
  local final="$2"
  [[ -f "$temp" ]] || {
    gate_error "Temporary file is missing: $temp"
    return 1
  }
  [[ ! -e "$final" ]] || {
    gate_error "Final file already exists: $final"
    return 1
  }
  mv "$temp" "$final" || {
    gate_error "Unable to promote temporary file: $temp"
    return 1
  }
}

require_no_clobber() {
  require_no_clobber_maybe "$@" || die "Final file already exists"
}

require_no_clobber_maybe() {
  local file
  for file in "$@"; do
    [[ ! -e "$file" ]] || {
      gate_error "Final file already exists: $file"
      return 1
    }
  done
}

gate_error() {
  printf '[%s] GATE: %s\n' "$(timestamp)" "$*" >&2
}

smoke_endpoint_url() {
  local path="$1"
  printf '%s/internal/exp-001/smoke/%s\n' "$APP_URL" "$path"
}

http_request_to_file() {
  local method="$1"
  local url="$2"
  local output="$3"
  local expected_status="$4"
  local max_time_seconds="$5"
  local temp="${output}.tmp.$$"
  local status
  local size

  [[ ! -e "$output" ]] || {
    gate_error "HTTP response file already exists: $output"
    return 1
  }
  rm -f "$temp"
  status="$("$CURL_BIN" --show-error --silent \
    --connect-timeout "$SMOKE_HTTP_CONNECT_TIMEOUT_SECONDS" \
    --max-time "$max_time_seconds" \
    --request "$method" \
    --write-out '%{http_code}' \
    --output "$temp" \
    "$url" 2>/dev/null)" || {
      rm -f "$temp"
      gate_error "HTTP request failed: $method $url"
      return 1
    }
  if [[ "$status" != "$expected_status" ]]; then
    rm -f "$temp"
    gate_error "HTTP status mismatch: expected=$expected_status actual=$status url=$url"
    return 1
  fi
  [[ -f "$temp" ]] || {
    gate_error "HTTP response body is missing"
    return 1
  }
  size="$(wc -c <"$temp" | tr -d ' ')"
  if [[ ! "$size" =~ ^[0-9]+$ || "$size" -gt "$SMOKE_RESPONSE_MAX_BYTES" ]]; then
    rm -f "$temp"
    gate_error "HTTP response size is invalid: $size"
    return 1
  fi
  mv "$temp" "$output"
}

assert_response_file_size() {
  local file="$1"
  local size
  [[ -f "$file" ]] || {
    gate_error "HTTP response body is missing: $file"
    return 1
  }
  size="$(wc -c <"$file" | tr -d ' ')"
  if [[ ! "$size" =~ ^[0-9]+$ || "$size" -gt "$SMOKE_RESPONSE_MAX_BYTES" ]]; then
    gate_error "HTTP response size is invalid: $size"
    return 1
  fi
}

write_json_gate_source() {
  local output="$1"
  cat >"$output" <<'JAVA'
import java.io.IOException;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Pattern;

public final class Exp001JsonGate {
    private static final Pattern CHECKSUM = Pattern.compile("[0-9a-f]{16}");
    private static final BigInteger LONG_MAX = BigInteger.valueOf(Long.MAX_VALUE);

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            fail("usage: <command> <json> [args]");
        }
        try {
            Object root = readJson(args[1]);
            switch (args[0]) {
                case "validate-ready" -> validateReady(root);
                case "validate-cpu" -> {
                    requireArgs(args, 3);
                    validateCpu(root, parseExpectedLong(args[2], "minimum duration"));
                }
                case "validate-allocation" -> {
                    requireArgs(args, 5);
                    validateAllocation(
                            root,
                            parseExpectedLong(args[2], "allocated bytes"),
                            parseExpectedLong(args[3], "chunk bytes"),
                            parseExpectedLong(args[4], "chunks"));
                }
                case "extract-engine" -> System.out.println(extractEngine(root));
                default -> fail("unknown command: " + args[0]);
            }
        } catch (GateException exception) {
            System.err.println("JSON_GATE: " + exception.getMessage());
            System.exit(2);
        } catch (Exception exception) {
            System.err.println("JSON_GATE: " + exception.getClass().getSimpleName() + ": " + exception.getMessage());
            System.exit(2);
        }
    }

    private static void requireArgs(String[] args, int count) {
        if (args.length != count) {
            fail("invalid argument count for " + args[0]);
        }
    }

    private static Object readJson(String file) throws IOException {
        String json = Files.readString(Path.of(file), StandardCharsets.UTF_8);
        try {
            return new Parser(json).parse();
        } catch (RuntimeException exception) {
            fail("malformed JSON: " + exception.getMessage());
            return null;
        }
    }

    private static void validateReady(Object root) {
        Map<String, Object> object = rootObject(root);
        exactKeys(object, "phase", "status");
        requireString(object, "status", "READY");
        requireString(object, "phase", "EXP001_SMOKE");
    }

    private static void validateCpu(Object root, long minimumDurationMillis) {
        Map<String, Object> object = rootObject(root);
        exactKeys(object, "checksum", "durationMillis", "iterations", "success", "workload");
        requireTrue(object, "success");
        requireString(object, "workload", "cpu");
        long duration = requirePositiveInteger(object, "durationMillis");
        if (duration < minimumDurationMillis) {
            fail("CPU smoke duration is below lower bound: " + duration);
        }
        requirePositiveInteger(object, "iterations");
        requireChecksum(object, "checksum");
    }

    private static void validateAllocation(Object root, long expectedAllocatedBytes, long expectedChunkBytes, long expectedChunks) {
        Map<String, Object> object = rootObject(root);
        exactKeys(object, "allocatedBytes", "checksum", "chunkBytes", "chunks", "success", "workload");
        requireTrue(object, "success");
        requireString(object, "workload", "allocation");
        requireEqualInteger(object, "allocatedBytes", expectedAllocatedBytes);
        requireEqualInteger(object, "chunkBytes", expectedChunkBytes);
        requireEqualInteger(object, "chunks", expectedChunks);
        requireChecksum(object, "checksum");
    }

    @SuppressWarnings("unchecked")
    private static String extractEngine(Object root) {
        Map<String, Object> object = rootObject(root);
        Object recording = object.get("recording");
        if (!(recording instanceof Map<?, ?>)) {
            fail("JFR JSON recording object is missing");
        }
        Map<?, ?> recordingMap = (Map<?, ?>) recording;
        Object events = ((Map<String, Object>) recordingMap).get("events");
        if (!(events instanceof List<?>)) {
            fail("JFR JSON events array is missing");
        }
        List<?> eventList = (List<?>) events;
        List<String> engines = new ArrayList<>();
        for (Object event : eventList) {
            if (!(event instanceof Map<?, ?>)) {
                continue;
            }
            Map<?, ?> eventMapRaw = (Map<?, ?>) event;
            Map<String, Object> eventMap = (Map<String, Object>) eventMapRaw;
            if (!"jdk.ActiveSetting".equals(eventMap.get("type"))) {
                continue;
            }
            Object values = eventMap.get("values");
            if (!(values instanceof Map<?, ?>)) {
                fail("jdk.ActiveSetting values object is missing");
            }
            Map<?, ?> valuesMapRaw = (Map<?, ?>) values;
            Map<String, Object> valuesMap = (Map<String, Object>) valuesMapRaw;
            if (!"engine".equals(valuesMap.get("name"))) {
                continue;
            }
            Object value = valuesMap.get("value");
            if (!(value instanceof String)) {
                fail("jdk.ActiveSetting engine value is not a string");
            }
            String engine = (String) value;
            if (!engine.equals("perf_events") && !engine.equals("ctimer")) {
                fail("unknown JFR CPU engine: " + engine);
            }
            engines.add(engine);
        }
        if (engines.size() != 1) {
            fail("JFR actual CPU engine detection is unresolved: matches=" + engines.size());
        }
        return engines.get(0);
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> rootObject(Object root) {
        if (!(root instanceof Map<?, ?>)) {
            fail("root JSON value must be an object");
        }
        Map<?, ?> map = (Map<?, ?>) root;
        return (Map<String, Object>) map;
    }

    private static void exactKeys(Map<String, Object> object, String... expectedKeys) {
        Set<String> actual = new TreeSet<>(object.keySet());
        Set<String> expected = new TreeSet<>(Arrays.asList(expectedKeys));
        if (!actual.equals(expected)) {
            fail("schema key mismatch: expected=" + expected + " actual=" + actual);
        }
    }

    private static void requireTrue(Map<String, Object> object, String key) {
        if (!Boolean.TRUE.equals(object.get(key))) {
            fail(key + " must be JSON boolean true");
        }
    }

    private static void requireString(Map<String, Object> object, String key, String expected) {
        Object value = object.get(key);
        if (!(value instanceof String)) {
            fail(key + " mismatch");
        }
        String actual = (String) value;
        if (!actual.equals(expected)) {
            fail(key + " mismatch");
        }
    }

    private static long requirePositiveInteger(Map<String, Object> object, String key) {
        long value = requireInteger(object, key);
        if (value <= 0L) {
            fail(key + " must be a positive integer");
        }
        return value;
    }

    private static void requireEqualInteger(Map<String, Object> object, String key, long expected) {
        long value = requireInteger(object, key);
        if (value != expected) {
            fail(key + " mismatch: " + value);
        }
    }

    private static long requireInteger(Map<String, Object> object, String key) {
        Object value = object.get(key);
        if (!(value instanceof JsonNumber)) {
            fail(key + " must be a JSON integer number");
        }
        JsonNumber number = (JsonNumber) value;
        if (!number.integral()) {
            fail(key + " must be a JSON integer number");
        }
        BigInteger parsed = new BigInteger(number.raw());
        if (parsed.signum() < 0 || parsed.compareTo(LONG_MAX) > 0) {
            fail(key + " integer is outside supported range");
        }
        return parsed.longValueExact();
    }

    private static void requireChecksum(Map<String, Object> object, String key) {
        Object value = object.get(key);
        if (!(value instanceof String)) {
            fail(key + " must be a 16-character lowercase hexadecimal string");
        }
        String text = (String) value;
        if (!CHECKSUM.matcher(text).matches()) {
            fail(key + " must be a 16-character lowercase hexadecimal string");
        }
    }

    private static long parseExpectedLong(String value, String name) {
        try {
            return Long.parseLong(value);
        } catch (NumberFormatException exception) {
            fail(name + " argument is not a long");
            return -1L;
        }
    }

    private static void fail(String message) {
        throw new GateException(message);
    }

    private record JsonNumber(String raw, boolean integral) {
    }

    private static final class GateException extends RuntimeException {
        private GateException(String message) {
            super(message);
        }
    }

    private static final class Parser {
        private final String text;
        private int index;

        private Parser(String text) {
            this.text = text;
        }

        private Object parse() {
            Object value = parseValue();
            skipWhitespace();
            if (index != text.length()) {
                fail("trailing data after JSON value");
            }
            return value;
        }

        private Object parseValue() {
            skipWhitespace();
            if (index >= text.length()) {
                fail("unexpected end of input");
            }
            char current = text.charAt(index);
            return switch (current) {
                case '{' -> parseObject();
                case '[' -> parseArray();
                case '"' -> parseString();
                case 't' -> parseLiteral("true", Boolean.TRUE);
                case 'f' -> parseLiteral("false", Boolean.FALSE);
                case 'n' -> parseLiteral("null", null);
                default -> {
                    if (current == '-' || isDigit(current)) {
                        yield parseNumber();
                    }
                    fail("unexpected character at offset " + index);
                    yield null;
                }
            };
        }

        private Map<String, Object> parseObject() {
            expect('{');
            LinkedHashMap<String, Object> object = new LinkedHashMap<>();
            skipWhitespace();
            if (consume('}')) {
                return object;
            }
            while (true) {
                skipWhitespace();
                if (index >= text.length() || text.charAt(index) != '"') {
                    fail("object key must be a string");
                }
                String key = parseString();
                if (object.containsKey(key)) {
                    fail("duplicate object key: " + key);
                }
                skipWhitespace();
                expect(':');
                Object value = parseValue();
                object.put(key, value);
                skipWhitespace();
                if (consume('}')) {
                    return object;
                }
                expect(',');
            }
        }

        private List<Object> parseArray() {
            expect('[');
            ArrayList<Object> array = new ArrayList<>();
            skipWhitespace();
            if (consume(']')) {
                return array;
            }
            while (true) {
                array.add(parseValue());
                skipWhitespace();
                if (consume(']')) {
                    return array;
                }
                expect(',');
            }
        }

        private String parseString() {
            expect('"');
            StringBuilder builder = new StringBuilder();
            while (index < text.length()) {
                char current = text.charAt(index++);
                if (current == '"') {
                    return builder.toString();
                }
                if (current < 0x20) {
                    fail("unescaped control character in string");
                }
                if (current != '\\') {
                    builder.append(current);
                    continue;
                }
                if (index >= text.length()) {
                    fail("unterminated escape sequence");
                }
                char escaped = text.charAt(index++);
                switch (escaped) {
                    case '"', '\\', '/' -> builder.append(escaped);
                    case 'b' -> builder.append('\b');
                    case 'f' -> builder.append('\f');
                    case 'n' -> builder.append('\n');
                    case 'r' -> builder.append('\r');
                    case 't' -> builder.append('\t');
                    case 'u' -> builder.append(parseUnicodeEscape());
                    default -> fail("invalid escape sequence");
                }
            }
            fail("unterminated string");
            return "";
        }

        private char parseUnicodeEscape() {
            if (index + 4 > text.length()) {
                fail("truncated unicode escape");
            }
            int value = 0;
            for (int offset = 0; offset < 4; offset++) {
                char current = text.charAt(index++);
                int digit = Character.digit(current, 16);
                if (digit < 0) {
                    fail("invalid unicode escape");
                }
                value = (value << 4) + digit;
            }
            return (char) value;
        }

        private Object parseLiteral(String literal, Object value) {
            if (!text.startsWith(literal, index)) {
                fail("invalid literal at offset " + index);
            }
            index += literal.length();
            return value;
        }

        private JsonNumber parseNumber() {
            int start = index;
            if (consume('-') && index >= text.length()) {
                fail("truncated number");
            }
            if (consume('0')) {
                if (index < text.length() && isDigit(text.charAt(index))) {
                    fail("leading zero in number");
                }
            } else {
                if (index >= text.length() || !isDigitOneToNine(text.charAt(index))) {
                    fail("invalid number");
                }
                while (index < text.length() && isDigit(text.charAt(index))) {
                    index++;
                }
            }
            boolean integral = true;
            if (consume('.')) {
                integral = false;
                requireDigit("fraction");
                while (index < text.length() && isDigit(text.charAt(index))) {
                    index++;
                }
            }
            if (index < text.length() && (text.charAt(index) == 'e' || text.charAt(index) == 'E')) {
                integral = false;
                index++;
                if (index < text.length() && (text.charAt(index) == '+' || text.charAt(index) == '-')) {
                    index++;
                }
                requireDigit("exponent");
                while (index < text.length() && isDigit(text.charAt(index))) {
                    index++;
                }
            }
            return new JsonNumber(text.substring(start, index), integral);
        }

        private void requireDigit(String section) {
            if (index >= text.length() || !isDigit(text.charAt(index))) {
                fail("number " + section + " requires a digit");
            }
        }

        private void skipWhitespace() {
            while (index < text.length()) {
                char current = text.charAt(index);
                if (current != ' ' && current != '\n' && current != '\r' && current != '\t') {
                    return;
                }
                index++;
            }
        }

        private void expect(char expected) {
            if (!consume(expected)) {
                fail("expected '" + expected + "' at offset " + index);
            }
        }

        private boolean consume(char expected) {
            if (index < text.length() && text.charAt(index) == expected) {
                index++;
                return true;
            }
            return false;
        }

        private static boolean isDigit(char value) {
            return value >= '0' && value <= '9';
        }

        private static boolean isDigitOneToNine(char value) {
            return value >= '1' && value <= '9';
        }
    }
}
JAVA
}

json_gate() {
  local command="$1"
  shift
  command -v "$JAVA_BIN" >/dev/null 2>&1 || {
    gate_error "JDK java tool is missing"
    return 1
  }
  local helper_dir="${EXP001_JSON_GATE_DIR:-${TMPDIR:-/tmp}/exp001-json-gate}"
  local source="$helper_dir/Exp001JsonGate.java"
  mkdir -p "$helper_dir" || {
    gate_error "Unable to create JSON gate helper directory"
    return 1
  }
  write_json_gate_source "$source" || {
    gate_error "Unable to write JSON gate helper source"
    return 1
  }
  "$JAVA_BIN" "$source" "$command" "$@"
}

assert_hex_checksum() {
  local value="$1"
  [[ "$value" =~ ^[0-9a-f]+$ ]] || {
    gate_error "checksum is not lowercase hex: $value"
    return 1
  }
}

assert_smoke_ready_response() {
  local file="$1"
  assert_response_file_size "$file" || return 1
  json_gate validate-ready "$file"
}

assert_cpu_smoke_response() {
  local file="$1"
  assert_response_file_size "$file" || return 1
  json_gate validate-cpu "$file" "$SMOKE_CPU_MIN_DURATION_MILLIS"
}

assert_allocation_smoke_response() {
  local file="$1"
  assert_response_file_size "$file" || return 1
  json_gate validate-allocation "$file" "$SMOKE_ALLOCATION_BYTES" "$SMOKE_ALLOCATION_CHUNK_BYTES" "$SMOKE_ALLOCATION_CHUNKS"
}

wait_for_smoke_ready() {
  local smoke_dir="$1"
  local response="$smoke_dir/ready.response.raw"
  local deadline=$((SECONDS + SMOKE_READY_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if http_request_to_file GET "$(smoke_endpoint_url ready)" "$response" 200 2; then
      assert_smoke_ready_response "$response" || die "smoke readiness response gate failed"
      return
    fi
    sleep "$SMOKE_READY_POLL_SECONDS"
  done
  die "smoke readiness endpoint did not become ready within ${SMOKE_READY_TIMEOUT_SECONDS}s"
}

call_smoke_workload() {
  local workload="$1"
  local output="$2"
  case "$workload" in
    cpu)
      http_request_to_file POST "$(smoke_endpoint_url cpu)" "$output" 200 10 || return 1
      assert_cpu_smoke_response "$output"
      ;;
    allocation)
      http_request_to_file POST "$(smoke_endpoint_url allocation)" "$output" 200 10 || return 1
      assert_allocation_smoke_response "$output"
      ;;
    *)
      gate_error "unsupported smoke workload: $workload"
      return 1
      ;;
  esac
}

current_uid() {
  id -u
}

proc_cmdline() {
  local pid="$1"
  tr '\0' ' ' <"$PROC_ROOT/$pid/cmdline" 2>/dev/null | sed 's/[[:space:]]*$//'
}

proc_environ() {
  local pid="$1"
  tr '\0' '\n' <"$PROC_ROOT/$pid/environ" 2>/dev/null
}

proc_uid() {
  local pid="$1"
  awk '/^Uid:/ {print $2; exit}' "$PROC_ROOT/$pid/status" 2>/dev/null
}

proc_start_identity() {
  local pid="$1"
  awk '{print $22}' "$PROC_ROOT/$pid/stat" 2>/dev/null
}

candidate_matches_target() {
  local pid="$1"
  [[ -r "$PROC_ROOT/$pid/cmdline" && -r "$PROC_ROOT/$pid/environ" && -r "$PROC_ROOT/$pid/status" && -r "$PROC_ROOT/$pid/stat" ]] || return 1

  local cmdline
  cmdline="$(proc_cmdline "$pid")" || return 1
  case "$cmdline" in
    *" -jar $APP_JAR "*|*" -jar $APP_JAR"|*" $APP_JAR "*|*"$APP_JAR") ;;
    *) return 1 ;;
  esac
  case "$cmdline" in
    *"--spring.profiles.active=$APP_PROFILE"*) ;;
    *)
      proc_environ "$pid" | grep -Fx "SPRING_PROFILES_ACTIVE=$APP_PROFILE" >/dev/null || return 1
      ;;
  esac

  local uid
  uid="$(proc_uid "$pid")" || return 1
  [[ "$uid" == "$(current_uid)" ]] || return 1
  [[ -n "$(proc_start_identity "$pid")" ]] || return 1
}

find_application_pid() {
  local matches=""
  local pid
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if candidate_matches_target "$pid"; then
      matches="${matches}${pid}
"
    fi
  done <<EOF
$(jcmd_list | awk '$1 ~ /^[0-9]+$/ {print $1}')
EOF

  local count
  count="$(printf '%s' "$matches" | awk 'NF > 0 {c++} END {print c+0}')"
  [[ "$count" == "1" ]] || die "Target JVM candidate count is not exactly one"
  printf '%s' "$matches" | awk 'NF > 0 {print; exit}'
}

jcmd_list() {
  if [[ -n "$JCMD_LIST_FILE" ]]; then
    cat "$JCMD_LIST_FILE"
  else
    jcmd -l
  fi
}

verify_jvm_identity() {
  check_jvm_identity "$@" || die "Target JVM identity no longer matches"
}

check_jvm_identity() {
  local pid="$1"
  local expected_start="$2"
  candidate_matches_target "$pid" || {
    gate_error "Target JVM identity no longer matches"
    return 1
  }
  [[ "$(proc_start_identity "$pid")" == "$expected_start" ]] || {
    gate_error "Target JVM start identity changed"
    return 1
  }
}

run_app() {
  exec "$JAVA_BIN" \
    -jar "$APP_JAR" \
    "--spring.profiles.active=${SPRING_PROFILES_ACTIVE:-exp001}"
}

validate_strategy() {
  case "$1" in
    jpa|jdbc) ;;
    *) die "Unsupported strategy" ;;
  esac
}

validate_event() {
  case "$1" in
    cpu|ctimer|alloc) ;;
    *) die "Unsupported profiler event" ;;
  esac
}

validate_cpu_engine() {
  case "$1" in
    cpu|ctimer) ;;
    *) die "Unsupported CPU engine" ;;
  esac
}

expected_repetitions() {
  local profile_id="$1"
  case "$profile_id" in
    cpu-jpa) printf '1\n' ;;
    cpu-jdbc) printf '25\n' ;;
    alloc-jdbc) printf '5\n' ;;
    alloc-jpa) printf '1\n' ;;
    *) die "Unsupported profile id" ;;
  esac
}

validate_profile_inputs() {
  local profile_id="$1"
  local event="$2"
  local cpu_engine="$3"
  local strategy="$4"
  local interval="$5"
  local chunk_index="$6"
  local count="$7"

  safe_name "$profile_id"
  validate_event "$event"
  validate_cpu_engine "$cpu_engine"
  validate_strategy "$strategy"
  [[ "$chunk_index" =~ ^[1-9][0-9]*$ ]] || die "Chunk index must be positive"
  [[ "$count" == "50000" ]] || die "EXP-001 profile chunks require exactly 50000 rows"

  local expected
  expected="$(expected_repetitions "$profile_id")"
  [[ "$chunk_index" -le "$expected" ]] || die "Chunk index exceeds configured repetitions"

  case "$profile_id:$event:$strategy:$interval" in
    cpu-jpa:cpu:jpa:10ms|cpu-jpa:ctimer:jpa:10ms) ;;
    cpu-jdbc:cpu:jdbc:10ms|cpu-jdbc:ctimer:jdbc:10ms) ;;
    alloc-jdbc:alloc:jdbc:512k) ;;
    alloc-jpa:alloc:jpa:512k) ;;
    *) die "Profile input combination does not match profile-config.json" ;;
  esac

  if [[ "$event" == "cpu" || "$event" == "ctimer" ]]; then
    [[ "$event" == "$cpu_engine" ]] || die "CPU event must match selected CPU engine"
  else
    [[ "$cpu_engine" == "cpu" || "$cpu_engine" == "ctimer" ]] || die "Selected CPU engine is required for allocation chunks"
  fi
}

endpoint_url() {
  local strategy="$1"
  validate_strategy "$strategy"
  printf '%s/internal/exp-001/%s\n' "$APP_URL" "$strategy"
}

call_endpoint() {
  local strategy="${EXP001_STRATEGY:-${1:-}}"
  local count="${EXP001_COUNT:-$DEFAULT_COUNT}"
  local output="${EXP001_RESPONSE_OUTPUT:-${2:-}}"
  validate_strategy "$strategy"
  [[ "$count" =~ ^[1-9][0-9]*$ ]] || die "count must be positive"
  [[ "$count" -le 50000 ]] || die "count must not exceed 50000"
  [[ -n "$output" ]] || die "response output path is required"
  validate_output_path "$output"
  call_endpoint_maybe "$strategy" "$count" "$output" || die "endpoint call failed"
}

call_endpoint_maybe() {
  local strategy="$1"
  local count="$2"
  local output="$3"

  case "$strategy" in
    jpa|jdbc) ;;
    *)
      gate_error "Unsupported strategy: $strategy"
      return 1
      ;;
  esac
  [[ "$count" =~ ^[1-9][0-9]*$ ]] || {
    gate_error "count must be positive"
    return 1
  }
  [[ "$count" -le 50000 ]] || {
    gate_error "count must not exceed 50000"
    return 1
  }
  [[ -n "$output" ]] || {
    gate_error "response output path is required"
    return 1
  }

  local temp="${output}.tmp.$$"
  rm -f "$temp"
  "$CURL_BIN" --fail --show-error --silent \
    --request POST \
    --header 'Content-Type: application/json' \
    --data "{\"count\":$count}" \
    "$(endpoint_url "$strategy")" >"$temp" || {
      rm -f "$temp"
      gate_error "endpoint HTTP request failed"
      return 1
    }
  grep -F '"valid":true' "$temp" >/dev/null || {
    rm -f "$temp"
    gate_error "endpoint response is not valid"
    return 1
  }
  promote_no_clobber_maybe "$temp" "$output" || {
    rm -f "$temp"
    return 1
  }
}

collapsed_counter_total() {
  local file="$1"
  awk '
    NF == 0 { next }
    {
      counter = $NF
      if (counter !~ /^[1-9][0-9]*$/) {
        exit 2
      }
      if (counter + 0 > 9007199254740991) {
        exit 3
      }
      total += counter
      if (total > 9007199254740991) {
        exit 4
      }
      lines++
    }
    END {
      if (lines == 0) {
        exit 5
      }
      printf "%.0f\n", total
    }
  ' "$file"
}

assert_counter_threshold() {
  local file="$1"
  local hard="$2"
  local recommended="$3"
  local name="$4"
  local total
  if ! total="$(collapsed_counter_total "$file")"; then
    gate_error "$name collapsed counter is malformed: $file"
    return 1
  fi
  if [[ ! "$total" =~ ^[0-9]+$ || "$total" -lt "$hard" ]]; then
    gate_error "$name collapsed counter is below hard threshold: actual=$total required=$hard"
    return 1
  fi
  if [[ "$total" -lt "$recommended" ]]; then
    printf '[%s] %s\n' "$(timestamp)" "$name collapsed counter is below recommended threshold: actual=$total recommended=$recommended" >&2
  fi
  printf '%s\n' "$total"
}

print_jfr_json() {
  local jfr="$1"
  local output="$2"
  local temp="${output}.tmp.$$"
  rm -f "$temp"
  [[ ! -e "$output" ]] || {
    gate_error "JFR JSON output already exists: $output"
    return 1
  }
  "$JFR_BIN" print --json --events jdk.ActiveSetting "$jfr" >"$temp" 2>"$temp.stderr" || {
    rm -f "$temp" "$temp.stderr"
    gate_error "jfr print --json failed: $jfr"
    return 1
  }
  [[ -s "$temp" ]] || {
    rm -f "$temp" "$temp.stderr"
    gate_error "jfr print --json produced empty output: $jfr"
    return 1
  }
  rm -f "$temp.stderr"
  mv "$temp" "$output"
}

extract_cpu_engine_from_jfr_json() {
  local json="$1"
  json_gate extract-engine "$json"
}

detect_actual_cpu_engine() {
  local jfr="$1"
  local json="$2"
  print_jfr_json "$jfr" "$json" || return 1
  extract_cpu_engine_from_jfr_json "$json"
}

asprof_start_maybe() {
  local event="$1"
  local interval="$2"
  local pid="$3"
  local temp_jfr="$4"
  local stderr_file="$5"
  require_no_clobber_maybe "$temp_jfr" "$stderr_file" "$stderr_file.stdout" || return 1
  rm -f "$temp_jfr"

  local rc=0
  case "$event" in
    cpu|ctimer)
      "$ASPROF_BIN" start -e "$event" -i "$interval" -o jfr -f "$temp_jfr" "$pid" >"$stderr_file.stdout" 2>"$stderr_file" || rc=$?
      ;;
    alloc)
      "$ASPROF_BIN" start -e alloc --alloc "$interval" -o jfr -f "$temp_jfr" "$pid" >"$stderr_file.stdout" 2>"$stderr_file" || rc=$?
      ;;
    *)
      return 2
      ;;
  esac
  if [[ "$rc" != "0" ]]; then
    rm -f "$temp_jfr"
    return "$rc"
  fi
}

asprof_start() {
  asprof_start_maybe "$@" || die "async-profiler start failed"
}

asprof_stop_jfr() {
  asprof_stop_jfr_maybe "$@" || die "async-profiler stop failed"
}

asprof_stop_jfr_maybe() {
  local pid="$1"
  local temp="$2"
  local output="$3"
  local stderr_file="$4"
  require_no_clobber_maybe "$output" "$stderr_file" "$stderr_file.stdout" || return 1
  "$ASPROF_BIN" stop "$pid" >"$stderr_file.stdout" 2>"$stderr_file" \
    || {
      rm -f "$temp"
      return 1
    }
  [[ -s "$temp" ]] || {
    rm -f "$temp"
    return 1
  }
  promote_no_clobber_maybe "$temp" "$output" || {
    rm -f "$temp"
    return 1
  }
}

convert_cpu_collapsed() {
  local jfr="$1"
  local output="$2"
  local temp="${output}.tmp.$$"
  require_no_clobber "$output"
  rm -f "$temp"
  "$JFRCONV_BIN" --cpu --dot --norm -o collapsed "$jfr" "$temp"
  [[ -s "$temp" ]] || die "CPU collapsed output is empty"
  promote_no_clobber "$temp" "$output"
}

convert_alloc_collapsed() {
  local jfr="$1"
  local samples_output="$2"
  local bytes_output="$3"
  local samples_temp="${samples_output}.tmp.$$"
  local bytes_temp="${bytes_output}.tmp.$$"
  require_no_clobber "$samples_output" "$bytes_output"
  rm -f "$samples_temp" "$bytes_temp"
  "$JFRCONV_BIN" --alloc --dot --norm -o collapsed "$jfr" "$samples_temp"
  "$JFRCONV_BIN" --alloc --total --dot --norm -o collapsed "$jfr" "$bytes_temp"
  [[ -s "$samples_temp" ]] || die "allocation sample collapsed output is empty"
  [[ -s "$bytes_temp" ]] || die "allocation byte collapsed output is empty"
  promote_no_clobber "$samples_temp" "$samples_output"
  promote_no_clobber "$bytes_temp" "$bytes_output"
}

record_chunk() {
  require_tool

  local profile_run_id="${EXP001_PROFILE_RUN_ID:-}"
  local profile_id="${EXP001_PROFILE_ID:-}"
  local event="${EXP001_EVENT:-}"
  local cpu_engine="${EXP001_CPU_ENGINE:-}"
  local strategy="${EXP001_STRATEGY:-}"
  local interval="${EXP001_INTERVAL:-}"
  local chunk_index="${EXP001_CHUNK_INDEX:-}"
  local count="${EXP001_COUNT:-$DEFAULT_COUNT}"

  [[ -n "$profile_run_id" ]] || die "EXP001_PROFILE_RUN_ID is required"
  [[ -n "$profile_id" ]] || die "EXP001_PROFILE_ID is required"
  [[ -n "$event" ]] || die "EXP001_EVENT is required"
  [[ -n "$cpu_engine" ]] || die "EXP001_CPU_ENGINE is required"
  [[ -n "$strategy" ]] || die "EXP001_STRATEGY is required"
  [[ -n "$interval" ]] || die "EXP001_INTERVAL is required"
  safe_name "$profile_run_id"
  validate_profile_inputs "$profile_id" "$event" "$cpu_engine" "$strategy" "$interval" "$chunk_index" "$count"

  local pid
  pid="$(find_application_pid)"
  local start_identity
  start_identity="$(proc_start_identity "$pid")" || die "Unable to read target JVM start identity"
  verify_jvm_identity "$pid" "$start_identity"

  local profile_dir="$ARTIFACT_ROOT/$profile_run_id/raw/$profile_id"
  ensure_dir "$profile_dir"
  local profile_dir_physical
  profile_dir_physical="$(cd "$profile_dir" && pwd -P)"
  local artifact_root_physical
  artifact_root_physical="$(cd "$ARTIFACT_ROOT" && pwd -P)"
  case "$profile_dir_physical" in
    "$artifact_root_physical"/*) ;;
    *) die "Profile output path escapes artifact root" ;;
  esac

  local chunk_text
  chunk_text="$(printf '%03d' "$chunk_index")"
  validate_basename "${chunk_text}-${strategy}-${event}"
  local prefix="$profile_dir/${chunk_text}-${strategy}-${event}"
  local response="$prefix.response.raw"
  local jfr="$prefix.jfr"
  local jfr_temp="${jfr}.tmp.$$"
  local start_log="$prefix.asprof-start.log"
  local stop_log="$prefix.asprof-stop.log"
  local session_active=0
  local failure_rc=0
  local failure_message=""
  local stop_failure_rc=0

  log "profile chunk start: profile=$profile_id strategy=$strategy event=$event chunk=$chunk_text"
  require_no_clobber "$jfr" "$jfr_temp" "$start_log" "$start_log.stdout" "$stop_log" "$stop_log.stdout"
  verify_jvm_identity "$pid" "$start_identity"
  asprof_start "$event" "$interval" "$pid" "$jfr_temp" "$start_log"
  session_active=1

  if ! call_endpoint_maybe "$strategy" "$count" "$response"; then
    failure_rc=20
    failure_message="endpoint call failed inside profile window"
  fi

  if [[ "$failure_rc" == "0" ]] && ! check_jvm_identity "$pid" "$start_identity"; then
    failure_rc=21
    failure_message="target JVM identity changed after profile chunk workload"
  fi

  if [[ "$failure_rc" != "0" ]]; then
    if [[ "$session_active" == "1" ]]; then
      if stop_profiler_best_effort "$pid" "$stop_log.best-effort"; then
        session_active=0
      else
        stop_failure_rc=$?
        gate_error "$failure_message; best-effort profiler stop also failed: rc=$stop_failure_rc"
      fi
    fi
    rm -f "$jfr_temp"
    if [[ "$stop_failure_rc" != "0" ]]; then
      die "$failure_message; profiler stop failed: rc=$stop_failure_rc"
    fi
    die "$failure_message"
  fi

  if ! asprof_stop_jfr_maybe "$pid" "$jfr_temp" "$jfr" "$stop_log"; then
    die "async-profiler stop failed"
  fi
  session_active=0

  if [[ "$event" == "alloc" ]]; then
    convert_alloc_collapsed "$jfr" "$prefix.alloc-samples.collapsed" "$prefix.alloc-bytes.collapsed"
  else
    convert_cpu_collapsed "$jfr" "$prefix.cpu.collapsed"
  fi

  log "profile chunk complete: profile=$profile_id strategy=$strategy event=$event chunk=$chunk_text"
}

stop_profiler_best_effort() {
  local pid="$1"
  local stderr_file="$2"
  rm -f "$stderr_file" "$stderr_file.stdout"
  "$ASPROF_BIN" stop "$pid" >"$stderr_file.stdout" 2>"$stderr_file"
}

smoke_one_event() {
  local event="$1"
  local interval="$2"
  local pid="$3"
  local start_identity="$4"
  local smoke_dir="$5"
  local workload="$6"
  local jfr="$smoke_dir/${event}.jfr"
  local jfr_temp="${jfr}.tmp.$$"
  local start_log="$smoke_dir/${event}.asprof-start.log"
  local stop_log="$smoke_dir/${event}.asprof-stop.log"
  local response="$smoke_dir/${event}.${workload}.response.raw"
  local collapsed
  local total
  local actual_engine
  local session_active=0
  local failure_rc=0
  local failure_message=""

  require_no_clobber "$jfr" "$jfr_temp" "$start_log" "$start_log.stdout" "$stop_log" "$stop_log.stdout" "$response"
  check_jvm_identity "$pid" "$start_identity" || return 9

  if ! asprof_start_maybe "$event" "$interval" "$pid" "$jfr_temp" "$start_log"; then
    return 10
  fi
  session_active=1

  if ! call_smoke_workload "$workload" "$response"; then
    failure_rc=20
    failure_message="smoke workload response gate failed"
  fi

  if [[ "$failure_rc" == "0" ]] && ! check_jvm_identity "$pid" "$start_identity"; then
    failure_rc=21
    failure_message="target JVM identity changed after smoke workload"
  fi

  if [[ "$failure_rc" != "0" ]]; then
    if [[ "$session_active" == "1" ]]; then
      if stop_profiler_best_effort "$pid" "$stop_log.best-effort"; then
        session_active=0
      else
        gate_error "$failure_message; best-effort profiler stop also failed"
      fi
    fi
    rm -f "$jfr_temp"
    gate_error "$failure_message"
    return "$failure_rc"
  fi

  if ! asprof_stop_jfr_maybe "$pid" "$jfr_temp" "$jfr" "$stop_log"; then
    return 30
  fi
  session_active=0
  if [[ "$event" == "alloc" ]]; then
    convert_alloc_collapsed "$jfr" "$smoke_dir/${event}.alloc-samples.collapsed" "$smoke_dir/${event}.alloc-bytes.collapsed" || return 40
    total="$(assert_counter_threshold "$smoke_dir/${event}.alloc-samples.collapsed" \
      "$SMOKE_ALLOCATION_HARD_SAMPLES" "$SMOKE_ALLOCATION_RECOMMENDED_SAMPLES" "allocation samples")" || return 41
    SMOKE_LAST_ALLOCATION_SAMPLE_COUNT="$total"
    total="$(assert_counter_threshold "$smoke_dir/${event}.alloc-bytes.collapsed" \
      "$SMOKE_ALLOCATION_HARD_BYTES" "$SMOKE_ALLOCATION_RECOMMENDED_BYTES" "allocation sampled bytes")" || return 42
    SMOKE_LAST_ALLOCATION_SAMPLED_BYTES="$total"
  else
    collapsed="$smoke_dir/${event}.cpu.collapsed"
    convert_cpu_collapsed "$jfr" "$collapsed" || return 40
    total="$(assert_counter_threshold "$collapsed" "$SMOKE_CPU_HARD_SAMPLES" "$SMOKE_CPU_RECOMMENDED_SAMPLES" "CPU samples")" || return 41
    SMOKE_LAST_CPU_SAMPLE_COUNT="$total"
    actual_engine="$(detect_actual_cpu_engine "$jfr" "$smoke_dir/${event}.jfr.json")" || return 42
    case "$event:$actual_engine" in
      cpu:perf_events|cpu:ctimer|ctimer:ctimer) ;;
      *) gate_error "JFR engine mismatch: requested=$event actual=$actual_engine"; return 43 ;;
    esac
    SMOKE_LAST_ACTUAL_ENGINE="$actual_engine"
  fi
}

smoke() {
  require_tool
  local smoke_id
  smoke_id="${EXP001_SMOKE_ID:-smoke-$(date -u '+%Y%m%dT%H%M%SZ')}"
  safe_name "$smoke_id"
  local smoke_dir="$ARTIFACT_ROOT/$smoke_id/raw/smoke"
  ensure_dir "$smoke_dir"

  wait_for_smoke_ready "$smoke_dir"

  local pid
  pid="$(find_application_pid)"
  local start_identity
  start_identity="$(proc_start_identity "$pid")" || die "Unable to read target JVM start identity"
  verify_jvm_identity "$pid" "$start_identity"

  local selected_cpu_engine=""
  local engine_verification=""
  local cpu_rc=0
  log "smoke attach start: event=cpu workload=cpu"
  if smoke_one_event cpu 10ms "$pid" "$start_identity" "$smoke_dir" cpu; then
    if [[ "$SMOKE_LAST_ACTUAL_ENGINE" == "perf_events" ]]; then
      selected_cpu_engine="cpu"
      engine_verification="$SMOKE_ENGINE_VERIFICATION_PERF_EVENTS"
    elif [[ "$SMOKE_LAST_ACTUAL_ENGINE" == "ctimer" ]]; then
      selected_cpu_engine="ctimer"
      engine_verification="$SMOKE_ENGINE_VERIFICATION_CTIMER"
    else
      die "ENGINE_DETECTION_UNRESOLVED"
    fi
  else
    cpu_rc=$?
    case "$cpu_rc" in
      10) ;;
      42) die "ENGINE_DETECTION_UNRESOLVED" ;;
      *) die "cpu smoke failed after profiler start: rc=$cpu_rc" ;;
    esac
    log "cpu profiler start failed; trying ctimer fallback"
    smoke_one_event ctimer 10ms "$pid" "$start_identity" "$smoke_dir" cpu || die "ctimer smoke failed"
    [[ "$SMOKE_LAST_ACTUAL_ENGINE" == "ctimer" ]] || die "ENGINE_DETECTION_UNRESOLVED"
    selected_cpu_engine="ctimer"
    engine_verification="$SMOKE_ENGINE_VERIFICATION_CTIMER"
  fi
  smoke_one_event alloc 512k "$pid" "$start_identity" "$smoke_dir" allocation || die "allocation smoke failed"

  verify_jvm_identity "$pid" "$start_identity"
  require_no_clobber "$smoke_dir/smoke-ready.json"
  printf '{"markerFormatVersion":%s,"smokeSuccess":true,"selectedCpuEngine":"%s","smokeProtocolVersion":"%s","cpuWorkloadVersion":"%s","allocationWorkloadVersion":"%s","cpuSampleCount":%s,"allocationSampleCount":%s,"allocationSampledBytes":%s,"engineVerification":"%s"}\n' \
    "$SMOKE_MARKER_FORMAT_VERSION" \
    "$selected_cpu_engine" \
    "$SMOKE_PROTOCOL_VERSION" \
    "$CPU_WORKLOAD_VERSION" \
    "$ALLOCATION_WORKLOAD_VERSION" \
    "$SMOKE_LAST_CPU_SAMPLE_COUNT" \
    "$SMOKE_LAST_ALLOCATION_SAMPLE_COUNT" \
    "$SMOKE_LAST_ALLOCATION_SAMPLED_BYTES" \
    "$engine_verification" >"$smoke_dir/smoke-ready.json"
  log "smoke complete"
}

action="${1:-help}"
shift || true

case "$action" in
  run-app) run_app "$@" ;;
  require-tool) require_tool ;;
  smoke) smoke ;;
  call) call_endpoint "$@" ;;
  record-chunk) record_chunk ;;
  fixture-find-pid) find_application_pid >/dev/null ;;
  fixture-verify-identity) verify_jvm_identity "$1" "$2" ;;
  fixture-validate-inputs) validate_profile_inputs "$@" ;;
  fixture-validate-output) validate_output_path "$1" ;;
  fixture-http-request) http_request_to_file "$@" ;;
  fixture-assert-ready-response) assert_smoke_ready_response "$1" ;;
  fixture-assert-cpu-response) assert_cpu_smoke_response "$1" ;;
  fixture-assert-allocation-response) assert_allocation_smoke_response "$1" ;;
  fixture-file-has-hex-byte) file_has_hex_byte "$1" "$2" ;;
  fixture-validate-asprof-version-stdout) validate_asprof_version_stdout "$1" "$2" ;;
  fixture-collapsed-total) collapsed_counter_total "$1" >/dev/null ;;
  fixture-parse-engine) extract_cpu_engine_from_jfr_json "$1" >/dev/null ;;
  fixture-smoke-one-event) smoke_one_event "$@" ;;
  help|-h|--help) show_help ;;
  *) show_help; die "Unknown action: $action" ;;
esac
