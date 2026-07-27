# EXP-001: JPA saveAll vs JDBC Batch

상태: 공개 재현 프로토콜. 공식 결과 1회 생성 완료.

- historical baseline: `private audit`
- related evidence: `EVD-001`
- public reproduction: `20260727T053643Z-2d76b26`
- public reproduction result: `results/exp-001/20260727T053643Z-2d76b26`
- public reproduction source revision: `2d76b26e716a5f1e471f225afe66128ebc948b26`

이 문서는 EXP-001의 단일 Source of Truth이다. 다른 문서는 공통 원칙이나 저장 정책만 설명할 수 있으며, 입력 건수, warm-up, official run 수, 실행 순서, timing boundary, 결과 채택 기준 같은 EXP-001 세부 규칙은 이 문서가 소유한다.

이 프로토콜은 비공개 과거 측정값을 공개하지 않으며, 이 Public 저장소가 기존 성능 결과를 재현했다고 주장하지 않는다.

## 공개 재현 결과

공식 public reproduction 결과는 `results/exp-001/20260727T053643Z-2d76b26`에 보존한다.

- summary: `results/exp-001/20260727T053643Z-2d76b26/summary.md`
- metadata: `results/exp-001/20260727T053643Z-2d76b26/metadata.md`
- raw official JSON: `results/exp-001/20260727T053643Z-2d76b26/official/`
- raw warm-up JSON: `results/exp-001/20260727T053643Z-2d76b26/warmup/`

이 결과는 단일 Windows official execution이며 warm-up은 official statistics에서 제외한다. Profiler와 k6는 사용하지 않았고, 다른 OS, JVM, DB, hardware에서 같은 성능을 보장하지 않는다.

## 목적

EXP-001은 다음 질문에 답한다.

현재 공개 구현이 동일한 50,000건의 deterministic synthetic record를 PostgreSQL에 저장할 때, JPA `saveAll` 경로와 JDBC `JdbcTemplate.batchUpdate` 경로는 동일한 검증 결과를 만들면서 elapsed time과 throughput에서 어떤 차이를 보이는가?

비교 대상은 현재 공개 구현으로 한정한다.

- JPA path: `JpaBenchmarkRecordPersistenceService.saveAll`
- JDBC path: `JdbcBatchBenchmarkRecordPersistenceService.saveAll`
- input: `BenchmarkRecordCommandGenerator.generate(50000)`
- table: `benchmark_record`
- ID strategy: `GenerationType.IDENTITY`

Public reproduction 결과는 모든 필수 consistency gate를 통과한 경우에만 채택한다.

## 구현 경계

EXP-001 구현은 script-first 구조를 사용한다.

애플리케이션에는 `exp001` profile에서만 등록되는 최소 profiling HTTP endpoint와 해당 endpoint가 호출하는 facade만 둔다. 이 코드는 deterministic input 생성, 기존 persistence service 호출, `System.nanoTime()` 측정, service 반환 후 consistency verification, 최소 response 반환만 담당한다.

외부 script harness는 `scripts/exp-001/`에 둔다. Windows는 `.cmd` launcher와 PowerShell `.ps1`을 사용하고, macOS는 Bash `.sh`를 사용한다. 다음 책임은 애플리케이션 안에 넣지 않는다.

- 애플리케이션 시작과 종료
- command와 환경 점검
- DB safety gate와 destructive reset
- warm-up
- official round 반복 실행
- timeout
- HTTP response JSON 저장
- summary Markdown 생성
- median, throughput, min/max/mean/stddev/CV 계산

이후 구현에서도 별도 승인 없이 M0 persistence path를 재설계하지 않는다. EXP-001 timing run은 script-first 구현이 `main`에 병합되고 clean public revision에서 실행되기 전까지 공식 결과가 아니다.

## 실행 방식

Platform별 `start` action이 `bootJar`를 생성한 뒤 별도 benchmark JVM을 `java -jar`로 실행한다. Spring profile은 `exp001`을 사용한다.

Script harness는 다음 profiling endpoint를 호출한다. Windows는 PowerShell HTTP 기능을 사용하고, macOS는 `curl`을 사용한다.

- `POST /internal/exp-001/jpa`
- `POST /internal/exp-001/jdbc`

Endpoint는 기본 profile과 운영 profile에서 등록되지 않는다. Controller는 request 수신, profiling facade 호출, response 반환만 담당한다.

Profiling facade는 Spring 안에서 실행되어 기존 persistence service를 Spring proxy를 통해 호출해야 한다. Facade 자체에 transactional persistence logic을 넣지 않는다.

k6 기반 동시성 실험은 EXP-001에 포함하지 않고 별도 EXP-002에서 다룬다.

## 측정 구간(Timing Boundary)

Timer는 persistence service 호출만 측정한다.

Timer 시작 시점:

- command list 생성 완료 후
- database reset 완료 후
- 시작 row count가 `0`임을 확인한 후
- profiling facade가 persistence service proxy를 호출하기 직전

Timer 종료 시점:

- persistence service proxy가 정상 반환한 직후

Timing에 포함:

- Spring transaction begin
- `BenchmarkRecordCommand`에서 JPA entity로의 변환
- JPA `saveAll`
- 명시적 JPA `flush`
- JDBC batch chunking과 binding
- `JdbcTemplate.batchUpdate`
- Spring transaction commit

Timing에서 제외:

- command generation
- DB reset
- row count `0` pre-check
- consistency verification
- environment collection
- result file writing
- summary calculation

Elapsed time은 `System.nanoTime()`으로 측정한다. Wall-clock timestamp에는 UTC `Instant`만 사용한다.

## Transaction Commit 요구사항

Profiling facade는 별도 Spring bean인 persistence service를 호출하는 Spring bean이어야 한다.

필수 구조:

- timer는 profiling facade에서 시작한다.
- facade는 별도 persistence service bean의 public method를 호출한다.
- persistence service public method에는 `@Transactional`이 적용된다.
- facade에는 `@Transactional`을 붙이지 않는다.
- facade와 persistence service는 같은 bean이 아니다.
- self-invocation은 금지한다.
- service proxy가 정상 반환한 뒤 timer를 종료한다.
- proxy 반환은 transaction commit 완료를 의미한다.
- consistency verification은 timer 종료 후 수행한다.

구현 리뷰에서는 이 구조를 반드시 검증한다.

## 입력

공식 EXP-001 input count는 정확히 `50,000`이다.

두 path는 한 run 안에서 사전 생성된 동일한 `List<BenchmarkRecordCommand>`를 전달받아야 한다. Command list generation은 timing boundary 밖에 둔다.

Expected business key는 deterministic하게 생성된다.

- `record-000001`
- `record-000002`
- ...
- `record-050000`

## Warm-up

Official timing 전에 warm-up을 수행한다.

- JPA warm-up count: 1
- JDBC warm-up count: 1
- warm-up input count: 50,000

Warm-up order:

1. DB Safety Gate 검증
2. reset
3. JPA warm-up
4. response 검증
5. cooldown
6. DB Safety Gate 재검증
7. reset
8. JDBC warm-up
9. response 검증
10. cooldown

Warm-up 결과는 `<run-id>/warmup/*.json`에 저장하고 official 12개 결과와 분리한다. Warm-up response에는 별도 marker field를 추가하지 않는다. Official 결과는 `<run-id>/official/*.json`에 저장하며, summary는 official JSON만 사용한다. Warm-up 결과는 official statistics에 포함하지 않는다.

## Official Runs

Official run count:

- JPA valid runs required: 6
- JDBC valid runs required: 6
- base set의 total official attempts: 12

Official set은 deterministic alternating order를 사용한다. 각 path가 first position과 second position을 각각 3회 갖도록 균형 있게 교대한다.

| Round | First | Second |
|---|---|---|
| 1 | JPA | JDBC |
| 2 | JDBC | JPA |
| 3 | JPA | JDBC |
| 4 | JDBC | JPA |
| 5 | JPA | JDBC |
| 6 | JDBC | JPA |

같은 run ID 안에서 부족한 valid run만 보충하지 않는다. 어느 path라도 valid official run이 6개보다 적으면 원인을 수정한 뒤 새 run ID로 전체 official set을 다시 실행한다.

## JVM 및 Gradle 실행

Gradle 실행 옵션과 benchmark JVM 옵션은 구분한다.

EXP-001의 Gradle process와 benchmark JVM은 `scripts/exp-001/tools/jdk.lock`에 고정된 Amazon Corretto JDK만 사용한다. 현재 고정값은 Amazon Corretto `21.0.11.10.1`, `JAVA_VERSION=21.0.11`이다.

Script harness는 `prepare`에서만 JDK 다운로드를 허용한다. `start`, `check`, `benchmark`는 local 또는 `.tools/jdk/<platform>/`에 이미 준비된 lock 일치 JDK만 검증하고 사용한다. lock 검증은 JDK home, `bin/java`, `bin/javac`, `release` 파일, `IMPLEMENTOR="Amazon.com Inc."`, `IMPLEMENTOR_VERSION="Corretto-21.0.11.10.1"`, `JAVA_VERSION="21.0.11"`, `java -version`, `javac -version`, major version `21`을 포함한다.

Gradle 실행 옵션:

- `--no-daemon`
- `--max-workers=1`

Benchmark JVM 옵션:

- `-Xms2g`
- `-Xmx2g`
- `-XX:+UseG1GC`
- `-Duser.timezone=UTC`

Benchmark JVM 옵션은 platform별 `start` action이 실행하는 `java -jar` process에 직접 적용해야 한다. 이 옵션을 Gradle process에만 적용하는 옵션으로 문서화하거나 구현하지 않는다.

Official run은 warm-up 이후 같은 benchmark JVM에서 수행한다. Run 사이에 `System.gc()`를 호출하지 않는다.

## Database 전략

Docker Compose Public lab PostgreSQL database를 사용한다.

- host: `localhost` 또는 `127.0.0.1`
- port: `55432`
- database: `persistence_lab`
- username: `lab_user`
- image: `postgres:17.6-alpine`

Compose DB는 official EXP-001 database target이다. Testcontainers는 automated test 용도로만 유지하며 official timing target으로 사용하지 않는다.

Harness는 Docker Desktop 설치, Docker Engine 시작, 권한 변경, WSL/UAC/group 변경, container/volume 삭제를 수행하지 않는다. Docker Compose PostgreSQL service는 사용자가 `docker compose up -d`로 미리 실행하고, harness는 command/Engine/Compose/service/running/health 상태만 확인한다.

각 warm-up과 official run은 비어 있는 `benchmark_record` table에서 시작한다. Reset은 timing boundary 밖에서 수행한다.

허용되는 reset command:

```sql
TRUNCATE TABLE benchmark_record RESTART IDENTITY;
```

Reset은 모든 safety gate가 통과한 경우에만 허용한다.

`check` action은 configured DB identity와 actual DB identity만 확인한다. `ALLOW_DESTRUCTIVE_RESET`은 reset 직전에만 확인한다.

Configuration gate:

- `ALLOW_DESTRUCTIVE_RESET=true`
- configured host가 `localhost` 또는 `127.0.0.1`
- configured port가 `55432`
- configured database가 `persistence_lab`
- configured username이 `lab_user`

Actual DB identity gate:

- Docker Compose PostgreSQL service 내부 `psql`의 `current_database()`가 `persistence_lab`를 반환
- Docker Compose PostgreSQL service 내부 `psql`의 `current_user`가 `lab_user`를 반환
- Docker Compose PostgreSQL service 내부 `psql`의 `SHOW transaction_isolation`이 `read committed`를 반환

Configured value 또는 actual connection identity 중 하나라도 다르면 reset과 official execution을 중단한다.

## 실행 환경 안정화

Official execution 전 script가 자동 확인하는 항목:

- locked Amazon Corretto JDK version
- application reachable
- required command: `git`, `docker compose`
- Windows required runtime: Windows PowerShell 5.1 이상
- macOS required runtime: macOS 기본 Bash, `curl`, `shasum`, `tar`
- JSON tool: `tools/jq.lock`에 고정된 portable `jq`
- DB client: Docker Compose PostgreSQL service 내부 `psql`
- project root
- result path
- configured DB identity
- actual DB identity
- transaction isolation
- Docker Engine 연결, Compose PostgreSQL service running 상태, health `healthy`

Official execution 전 수동 확인 항목:

- 전원 케이블 연결
- 고성능 전원 모드 선택
- 불필요한 애플리케이션 종료
- debugger disabled
- IDE profiler disabled
- external profiler 미연결
- 알려진 background CPU 또는 disk-heavy job 없음

금지 상태:

- dirty working tree
- Docker healthcheck not healthy
- SQL logging enabled
- Hibernate bind logging enabled
- Hibernate statistics enabled
- profiler attached to timing run
- DB safety gate mismatch

## 고정 설정(Frozen Configuration)

| 항목 | 값 또는 기록 정책 |
|---|---|
| Java | Gradle toolchain `21`; Amazon Corretto `21.0.11.10.1`, `JAVA_VERSION=21.0.11` lock 검증 |
| Spring Boot | `3.5.16` |
| Gradle Wrapper | `8.14.4` |
| Gradle execution | `bootJar` 생성 시 `--no-daemon --max-workers=1` 사용 |
| Benchmark JVM heap | `java -jar` JVM에 `-Xms2g -Xmx2g` 적용 |
| Benchmark JVM GC | `java -jar` JVM에 `-XX:+UseG1GC` 적용 |
| Timezone | `java -jar` JVM에 `-Duser.timezone=UTC` 적용 |
| PostgreSQL image | `postgres:17.6-alpine` |
| Git revision | run ID에 short public Git SHA 포함 |
| JPA ID strategy | `GenerationType.IDENTITY` |
| Hibernate batch size | `not configured` |
| Hibernate `order_inserts` | `not configured` |
| JDBC batch size | default `1000`; effective value 기록 |
| `rewriteBatchedInserts` | `not configured` |
| Hikari `maximumPoolSize` | `exp001` profile에서 `4`로 고정 |
| Hikari `minimumIdle` | `exp001` profile에서 `1`로 고정 |
| Hikari connection timeout | `exp001` profile에서 `30000ms`로 고정 |
| transaction isolation | script gate에서 `read committed` 확인 |
| input count | `50000` |
| warm-up count | 이 문서의 path별 count 사용 |
| official run count | 이 문서의 path별 count 사용 |

## 정합성 Gate(Consistency Gate)

각 official run은 다음을 검증해야 한다.

- expected row count: `50000`
- actual row count
- distinct business key count
- missing key count
- duplicate key count
- expected checksum
- actual checksum
- saved count 또는 update count
- exception absence

Invalid 조건:

- row count mismatch
- key set mismatch
- checksum mismatch
- duplicate business key exists
- missing key exists
- saved count mismatch
- transaction failure
- DB connection error
- timeout
- environment collection failure
- elapsed time is not positive

HTTP failure, timeout, JSON parse failure, consistency failure는 해당 official set을 즉시 중단한다. 실패한 response는 final official JSON으로 승격하지 않고, 부족한 step만 보충하지 않는다. 원인을 수정한 뒤 새 run ID로 전체 official set을 다시 실행한다.

## 지표와 통계(Metrics And Statistics)

Endpoint response field:

- `path`
- `inputCount`
- `savedCount`
- `elapsedNanos`
- `elapsedMillis`
- `valid`
- `rowCount`
- `distinctBusinessKeyCount`
- `missingKeyCount`
- `unexpectedKeyCount`
- `duplicateKeyCount`
- `expectedChecksum`
- `actualChecksum`

Endpoint가 반환하는 raw HTTP response에는 `resultFormatVersion`과 `elapsedSeconds`를 포함하지 않는다. 이 두 field는 script harness가 timer 밖 post-processing 단계에서만 추가한다.

Future result JSON은 다음 v2 field를 추가한다.

- `resultFormatVersion`: JSON integer `2`
- `elapsedSeconds`: `elapsedNanos / 1_000_000_000`에서 파생한 finite positive JSON number

Legacy result는 `resultFormatVersion`과 `elapsedSeconds`가 모두 없는 파일이다. `resultFormatVersion` 없이 `elapsedSeconds`만 있는 파일은 ambiguous artifact로 거부한다. `resultFormatVersion`이 `2`가 아니거나 v2에서 `elapsedSeconds`가 없거나 numeric relation을 만족하지 않으면 거부한다. Summary는 legacy와 v2가 섞인 official set을 허용하되 각 파일을 자기 schema로 검증한다.

`elapsedNanos`가 elapsed time의 Source of Truth이다. `elapsedMillis`와 `elapsedSeconds`는 `elapsedNanos`에서 파생된 값으로만 취급하며 직접 equality 비교 대신 tolerance 기반 numeric relation으로 검증한다.

Script는 검증을 통과한 warm-up과 official response JSON을 파일로 보존한다. Official round와 order position은 파일명으로 식별한다. Summary는 official basename 목록이 `round-01-01-jpa.json`, `round-01-02-jdbc.json`, `round-02-01-jdbc.json`, `round-02-02-jpa.json`, `round-03-01-jpa.json`, `round-03-02-jdbc.json`, `round-04-01-jdbc.json`, `round-04-02-jpa.json`, `round-05-01-jpa.json`, `round-05-02-jdbc.json`, `round-06-01-jdbc.json`, `round-06-02-jpa.json` 순서와 정확히 일치하고 filename strategy와 JSON `path`가 일치할 때만 생성한다. Future JSON은 portable `jq` serializer의 2-space pretty output을 사용하며 UTF-8 no BOM, LF, final newline exactly once, NUL 없음 정책을 따른다.

대표 통계:

- median elapsed time
- median rows per second

참고 통계:

- min
- max
- mean
- standard deviation
- coefficient of variation

각 path의 official sample이 6개뿐이므로 EXP-001에서는 p95를 계산하지 않는다. p95는 더 큰 sample size를 사용하는 후속 실험에서만 검토한다.

계산 정책:

- `rowsPerSecond = inputCount * 1_000_000_000 / elapsedNanos`
- median speedup은 `JPA median elapsedNanos / JDBC median elapsedNanos`로 계산
- JDBC median elapsed reduction은 `(1 - JDBC median elapsedNanos / JPA median elapsedNanos) * 100`으로 계산
- mean speedup은 raw `elapsedNanos` mean으로 계산
- 반올림은 표시 단계에서만 수행
- JSON number token은 exponent notation을 허용하지만 Markdown에는 fixed decimal display만 사용
- human duration은 `elapsedNanos`에서 직접 계산하고 `647.975ms`, `8.783s`, `1m 16.685s` 형태로 표시
- elapsed seconds는 소수 9자리로 표시
- elapsed milliseconds는 소수 3자리로 표시
- rows per second는 소수 2자리로 표시
- percentage는 소수 2자리로 표시
- denominator가 `0`이면 `null` 출력

## Timing과 Profiling 경계

EXP-001은 timing + consistency only로 수행한다.

Official timing run 중에는 CPU profiling, sampled allocation profiling, JFR, heap dump collection을 실행하지 않는다.

async-profiler 작업이 나중에 필요하면 외부 profiling subphase로 분리하고 별도 결과로 남긴다. Profiler output은 official timing representative data로 사용하지 않는다.

Profiler HTML, raw stack traces, JFR files, heap dumps, large logs, DB dumps는 commit하지 않는다.

## 결과 구조(Result Structure)

Script harness output은 다음 구조를 사용한다.

- run ID: UTC `yyyyMMdd'T'HHmmss'Z'-<shortGitSha>`
- directory: `results/exp-001/<run-id>/`
- `warmup/*.json`
- `official/*.json`
- `summary.md`

Run ID에는 user name, host-specific absolute path, secret을 포함하지 않는다.

기존 official public reproduction `results/exp-001/20260727T053643Z-2d76b26`은 immutable legacy artifact로 보존한다. 새 formatter와 summary 정책을 검증하더라도 이 directory의 14개 JSON, `summary.md`, `metadata.md`는 rewrite하지 않는다.

Future summary는 portable `jq` filter가 official JSON 12개와 exact basename/order를 모두 검증한 뒤 생성한다. Summary section은 Run Metadata, Official Run Table, Statistical Summary, Median Unit Overview, Throughput Summary, Derived Comparison, Interpretation Boundary 순서를 사용한다. Warm-up은 제외하고 p95는 계산하지 않는다. Derived Comparison은 median speedup, JDBC median elapsed reduction, mean speedup만 포함한다.

## Fixture 검증

Harness fixture는 official benchmark나 application lifecycle을 실행하지 않고 OS temporary directory에서만 generated artifact를 만든다.

Windows PowerShell runner:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/exp-001/tests/run-fixtures.ps1
```

Bash runner:

```bash
bash scripts/exp-001/tests/run-fixtures.sh
```

Windows Git Bash에서 Bash runner를 실행할 때는 repository에 준비된 locked Windows `jq` 1.7.1 binary를 `EXP001_JQ_BIN_OVERRIDE`로 사용한다. 이 검증은 shared jq semantics, byte policy, summary gate, no-clobber promotion test를 확인하지만 actual macOS 기본 Bash 3.2 runtime 검증을 대체하지 않는다.

## 재현 명령(Reproduction Commands)

다음 명령은 script-first 구현이 `main`에 병합된 뒤 clean public revision에서 사용할 재현 명령이다. 공식 실행 전 `.env`를 확인하고 destructive reset 승인 값을 명시적으로 바꿔야 한다.

Windows:

```cmd
git switch main
git pull --ff-only origin main
git status --short --branch
docker compose up -d
docker inspect --format "{{.State.Health.Status}}" spring-persistence-performance-lab-postgres
scripts\exp-001\windows\exp001.cmd prepare
scripts\exp-001\windows\exp001.cmd start
scripts\exp-001\windows\exp001.cmd check
scripts\exp-001\windows\exp001.cmd benchmark
scripts\exp-001\windows\exp001.cmd summary
scripts\exp-001\windows\exp001.cmd stop
git status --short --branch
docker compose down
```

macOS:

```bash
git switch main
git pull --ff-only origin main
git status --short --branch
docker compose up -d
docker inspect --format '{{.State.Health.Status}}' spring-persistence-performance-lab-postgres
./scripts/exp-001/macos/exp001.sh prepare
./scripts/exp-001/macos/exp001.sh start
./scripts/exp-001/macos/exp001.sh check
./scripts/exp-001/macos/exp001.sh benchmark
./scripts/exp-001/macos/exp001.sh summary
./scripts/exp-001/macos/exp001.sh stop
git status --short --branch
docker compose down
```

Official execution 직전 working tree가 dirty이면 run을 중단한다.

## Historical Baseline 정책

다음 label은 분리해서 유지한다.

- Historical baseline
- Public reproduction

기존 private measurement는 public reproduction result가 아니다. Public result가 historical baseline과 다르면 어느 한쪽을 덮어쓰지 않는다. 차이는 environment, configuration 또는 implementation difference로 분석한다.
