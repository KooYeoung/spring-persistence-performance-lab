# EXP-001 cross-platform harness

이 디렉터리는 EXP-001을 script-first 방식으로 실행하기 위한 외부 실험 하네스이다.

애플리케이션은 `exp001` profile에서 최소 HTTP endpoint만 제공한다. 애플리케이션 시작과 종료, DB Safety Gate, reset, warm-up, official round 실행, timeout, 결과 저장, JSON 검증, summary 계산은 이 하네스가 담당한다.

## 지원 플랫폼

Windows에서는 Git Bash나 WSL을 요구하지 않는다.

```cmd
scripts\exp-001\windows\exp001.cmd help
scripts\exp-001\windows\exp001.cmd prepare
scripts\exp-001\windows\exp001.cmd start
scripts\exp-001\windows\exp001.cmd check
scripts\exp-001\windows\exp001.cmd benchmark
scripts\exp-001\windows\exp001.cmd summary
scripts\exp-001\windows\exp001.cmd stop
```

macOS에서는 PowerShell을 요구하지 않는다.

```bash
./scripts/exp-001/macos/exp001.sh help
./scripts/exp-001/macos/exp001.sh prepare
./scripts/exp-001/macos/exp001.sh start
./scripts/exp-001/macos/exp001.sh check
./scripts/exp-001/macos/exp001.sh benchmark
./scripts/exp-001/macos/exp001.sh summary
./scripts/exp-001/macos/exp001.sh stop
```

`all` action은 제공하지 않는다. DB reset을 포함한 전체 실험이 한 번의 실수로 자동 실행되지 않도록 각 action을 명시적으로 호출한다.

## 필수 도구

공통 필수 도구:

- Git
- Docker Desktop
- Docker Compose

Windows:

- Windows PowerShell 5.1 이상

macOS:

- macOS 기본 Bash
- `curl`
- `shasum`
- `tar`

local `psql`과 system-wide `jq` 설치는 필요하지 않다. PostgreSQL 확인과 reset은 Docker Compose service 내부의 `psql`을 사용한다. JSON 검증과 summary 계산은 `prepare`가 `.tools/` 아래에 준비하는 portable `jq`를 사용한다.

Java runtime은 `tools/jdk.lock`에 고정된 Amazon Corretto JDK만 사용한다. 현재 lock은 Amazon Corretto `21.0.11.10.1`, `JAVA_VERSION=21.0.11`을 대상으로 하며, `release` 파일의 `IMPLEMENTOR`, `IMPLEMENTOR_VERSION`, `JAVA_VERSION`, `java -version`, `javac -version`, major version `21`을 모두 검증한다.

## 준비

`prepare`는 `.env`가 없으면 `.env.example`을 복사하고, `.state`, result root, portable `jq`, lock된 Amazon Corretto JDK를 준비한다. 애플리케이션 실행, DB 연결, DB reset, benchmark 실행은 수행하지 않는다.

공식 실행 전에는 `.env`를 열어 값을 확인하고, destructive reset을 허용할 때만 `ALLOW_DESTRUCTIVE_RESET=true`로 바꾼다.

Portable `jq`는 `tools/jq.lock`에 고정된 version, official release URL, SHA-256으로만 다운로드한다. `.tools/`의 binary는 Git에 포함하지 않는다.

Portable JDK는 `tools/jdk.lock`에 고정된 official release URL, SHA-256, archive type, archive 내부 JDK home으로만 다운로드한다. `prepare`만 다운로드를 허용한다. `start`, `check`, `benchmark`는 local 또는 `.tools/jdk/<platform>/`에 이미 준비된 lock 일치 JDK만 사용하며, 없으면 `prepare` 실행을 안내하고 중단한다.

Docker는 harness가 설치하거나 시작하지 않는다. `prepare`, `start`, `check`, `benchmark`는 Docker command, Engine 연결, Compose plugin, `persistence-lab-postgres` service 존재, container running 상태, health `healthy`만 확인한다.

## DB Safety Gate

`check`는 configured DB identity와 actual DB identity만 확인하며 `ALLOW_DESTRUCTIVE_RESET` 값을 읽지 않는다.

DB reset은 다음 조건이 모두 일치할 때만 수행된다.

- `ALLOW_DESTRUCTIVE_RESET=true`
- `DB_HOST`가 정확히 `localhost` 또는 `127.0.0.1`
- `DB_PORT=55432`
- `DB_NAME=persistence_lab`
- `DB_USER=lab_user`
- container 내부 `psql`의 `current_database()`가 `persistence_lab`
- container 내부 `psql`의 `current_user`가 `lab_user`
- container 내부 `psql`의 `transaction_isolation`이 `read committed`

Reset SQL은 다음 하나만 허용된다.

```sql
TRUNCATE TABLE benchmark_record RESTART IDENTITY;
```

Gate가 하나라도 실패하면 reset, warm-up, official run을 중단한다. Timeout, catch, cleanup 흐름에서는 자동 reset을 수행하지 않는다.

## 결과와 실패 처리

결과는 project root 기준 `RESULT_ROOT` 아래에 저장된다. 기본값은 `results/exp-001`이다.

`RESULT_ROOT`는 repository-relative portable path만 허용한다. Absolute path, Windows drive/UNC path, backslash, `~`, `.` 또는 `..` segment, project root 자체, symlink/junction을 통한 repository 밖 경로는 중단한다.

```text
results/exp-001/<run-id>/
  warmup/*.json
  official/*.json
  summary.md
```

Run ID는 UTC timestamp와 short public Git SHA만 사용하며 사용자명, host-local absolute path, secret을 포함하지 않는다.

HTTP response는 final JSON에 직접 쓰지 않는다. HTTP 성공 body는 `<final>.raw.tmp.<pid>`에 기록하고 raw schema validation을 통과한 뒤, timer 밖 `format-response.jq` 단계에서 `<final>.pretty.tmp.<pid>`로 v2 pretty JSON을 생성한다. v2 validation, UTF-8 no BOM/LF/final newline/NUL byte 검사, raw와 formatted JSON의 semantic equality 검증을 모두 통과한 pretty temp만 final path로 이동한다. 실패 시 temporary file을 삭제하고 다음 reset/run을 수행하지 않는다.

Raw HTTP response에는 `resultFormatVersion`과 `elapsedSeconds`가 없어야 한다. Future final JSON은 `resultFormatVersion: 2`와 `elapsedSeconds`를 포함한다. Existing legacy result처럼 두 field가 모두 없는 JSON은 summary 입력으로 계속 허용하지만, `resultFormatVersion` 없이 `elapsedSeconds`만 있는 파일은 ambiguous artifact로 거부한다.

`summary.md`는 official JSON이 정확히 12개이고, basename이 `round-01-01-jpa.json`부터 `round-06-02-jpa.json`까지 기대 순서와 정확히 일치하며, filename strategy와 JSON `path`가 일치할 때만 생성한다. JPA 6개와 JDBC 6개가 모두 `valid=true`이고 checksum 형식과 equality를 통과해야 한다. Legacy와 v2가 섞인 official set도 파일별 schema validation을 통과하면 허용한다. Warm-up JSON은 보존하지만 공식 통계에는 포함하지 않는다. Summary 통계는 `elapsedNanos`를 Source of Truth로 사용하고 seconds-first table, median unit overview, throughput summary를 분리해서 출력한다. Derived Comparison은 median speedup, JDBC median elapsed reduction, mean speedup만 출력한다. p95는 계산하지 않는다.

Windows harness는 jq stdout을 PowerShell string으로 받지 않고 `ProcessStartInfo` stdout stream을 file stream으로 복사한다. jq output은 Windows에서도 `-b` binary mode로 받아 LF byte policy를 유지한다.

Fixture 검증은 다음 명령으로 실행한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/exp-001/tests/run-fixtures.ps1
```

```bash
bash scripts/exp-001/tests/run-fixtures.sh
```

Windows Git Bash에서 Bash fixture runner를 실행할 때는 repository의 locked Windows `jq` 1.7.1 binary를 명시 override로 사용한다. 이는 shared jq semantics와 Bash runner 검증용이며, actual macOS 기본 Bash 3.2 runtime 검증을 대체하지 않는다.

Fixture와 golden file은 `scripts/exp-001/tests/fixtures/*.json`, `scripts/exp-001/tests/expected/*.json`, `scripts/exp-001/tests/expected/*.md`에 있으며 Git attribute로 `text eol=lf`를 고정한다.

Timeout 후에는 애플리케이션 내부 작업이 계속될 수 있다. 이 경우 자동 reset이나 부족한 step 보충을 하지 말고, 애플리케이션과 DB 상태를 확인한 뒤 새 run ID로 전체 official set을 다시 시작한다.

## Async-profiler Phase B

Smoke readiness contract는 `GET /internal/exp-001/smoke/ready` HTTP `200` response의 exact JSON object `{ "status": "READY", "phase": "EXP001_SMOKE" }`이다. Smoke workload response는 structural JSON gate로 전체 문법, duplicate/unknown/missing key, wrong type, malformed/trailing garbage, size 초과, HTTP `409`/`500`을 fail-closed로 거부한다. Active profiler session 구간의 workload 실패와 JVM identity mismatch는 profiler stop을 먼저 시도한 뒤 실패로 보고한다.

CPU actual engine은 JFR `jdk.ActiveSetting` event 중 `values.name=engine`의 `values.value`에서만 확인한다. `perf_events`이면 marker의 `selectedCpuEngine=cpu`, `ctimer`이면 `selectedCpuEngine=ctimer`로 기록하고 후속 CPU profile chunk는 marker 값을 사용한다. `engineVerification`은 `jfr-active-setting-engine:perf_events` 또는 `jfr-active-setting-engine:ctimer`만 허용하며, parser 실패나 sample hard threshold 미달이면 marker를 생성하지 않는다.

CPU/allocation 원인 분석용 harness는 `scripts/exp-001/profiler/`에 분리한다.

Phase B profiler harness는 Phase A official timing result를 갱신하지 않는다. Actual 50,000-row profile execution은 smoke 통과 후 별도 명시 실행에서만 허용하며, raw JFR/HTML/collapsed/log는 Git에 포함하지 않는다.

Phase B smoke는 DB를 사용하지 않는 `exp001` 전용 endpoint 세 개로 profiler attach와 conversion을 검증한다. `GET /internal/exp-001/smoke/ready`가 준비되면 CPU smoke는 3초 workload와 CPU sample hard minimum `50`을 검증하고, allocation smoke는 64MiB allocation workload와 allocation sample/byte hard minimum을 검증한다. `selectedCpuEngine=cpu`는 JFR actual engine이 `perf_events`로 확인된 경우에만 허용하며, fallback은 `ctimer`로 marker에 기록한다.

Smoke marker는 `markerFormatVersion=2`이며 sample count, sampled bytes, workload protocol version, engine verification을 포함한다. Marker는 cleanup 성공 후에만 final path로 승격된다. 실패 후 operator cleanup이 필요하면 다음 명령을 사용한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/exp-001/profiler/windows/exp001-profile.ps1 cleanup -SecurityLevel 0
```

Profiler fixture는 다음 명령으로 별도 검증한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/exp-001/tests/run-profiler-fixtures.ps1
```

Git Bash profiler fixture는 runner 자체가 계산한 immutable repository root를 사용해 실제 official result manifest 16개 파일의 SHA를 비교한다. Phase B profile은 smoke marker의 `selectedCpuEngine`과 revision/version binding이 현재 harness와 일치할 때만 허용한다.
