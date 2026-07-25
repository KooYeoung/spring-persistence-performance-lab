# EXP-001: JPA saveAll vs JDBC Batch

상태: 공개 재현 프로토콜. 아직 실행하지 않음.

- historical baseline: `private audit`
- related evidence: `EVD-001`
- public reproduction: `not executed`

이 문서는 EXP-001의 단일 Source of Truth이다. 다른 문서는 공통 원칙이나 저장 정책만 설명할 수 있으며, 입력 건수, warm-up, official run 수, 실행 순서, timing boundary, 결과 채택 기준 같은 EXP-001 세부 규칙은 이 문서가 소유한다.

이 프로토콜은 비공개 과거 측정값을 공개하지 않으며, 이 Public 저장소가 기존 성능 결과를 재현했다고 주장하지 않는다.

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

이 프로토콜 문서는 benchmark runner를 구현하지 않는다.

Runner 구현은 이 프로토콜이 `main`에 병합된 뒤 별도 feature branch와 PR에서 진행한다. 이후 구현에서도 별도 승인 없이 M0 persistence path를 재설계하지 않는다.

향후 runner 구현은 다음을 제공해야 한다.

- command-line Spring Boot benchmark runner
- PowerShell에서 benchmark를 실행할 수 있는 Gradle task
- DB safety gate와 reset logic
- environment collection
- result writing
- summary calculation
- runner, safety gate, statistics, result writing 테스트

EXP-001 timing run은 해당 구현이 `main`에 병합되고 clean public revision에서 실행되기 전까지 공식 결과가 아니다.

## 실행 방식

전용 Gradle task로 호출되는 Spring Boot command-line benchmark runner를 사용한다.

EXP-001에서도 Controller나 benchmark HTTP endpoint를 추가하지 않는다.

Runner는 Spring 안에서 실행되어 기존 persistence service를 Spring proxy를 통해 호출해야 한다. Runner 자체에 transactional persistence logic을 넣지 않는다.

## 측정 구간(Timing Boundary)

Timer는 persistence service 호출만 측정한다.

Timer 시작 시점:

- command list 생성 완료 후
- database reset 완료 후
- 시작 row count가 `0`임을 확인한 후
- runner bean이 persistence service proxy를 호출하기 직전

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

Benchmark runner는 별도 Spring bean인 persistence service를 호출하는 Spring bean이어야 한다.

필수 구조:

- timer는 benchmark runner bean에서 시작한다.
- runner는 별도 persistence service bean의 public method를 호출한다.
- persistence service public method에는 `@Transactional`이 적용된다.
- runner와 persistence service는 같은 bean이 아니다.
- self-invocation은 금지한다.
- service proxy가 정상 반환한 뒤 timer를 종료한다.
- proxy 반환은 transaction commit 완료를 의미한다.

Runner 구현 리뷰에서는 이 구조를 반드시 검증한다.

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
- warm-up order: JPA, reset, JDBC, reset

Warm-up 기록은 raw record에만 `warmup=true`로 남긴다. Official statistics에는 포함하지 않는다.

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

Gradle 실행 옵션:

- `--no-daemon`
- `--max-workers=1`

Benchmark JVM 옵션:

- `-Xms2g`
- `-Xmx2g`
- `-XX:+UseG1GC`
- `-Duser.timezone=UTC`

Benchmark JVM 옵션은 향후 `runExp001` task가 사용하는 forked benchmark JVM에 직접 적용해야 한다. 예를 들어 `JavaExec.jvmArgs` 또는 동등한 forked JVM 실행 방식에 적용한다. 이 옵션을 Gradle process에만 적용하는 옵션으로 문서화하거나 구현하지 않는다.

Official run은 warm-up 이후 하나의 benchmark JVM에서 수행한다. Run 사이에 `System.gc()`를 호출하지 않는다. Environment output에는 effective JVM arguments와 GC name을 기록한다.

## Database 전략

Docker Compose Public lab PostgreSQL database를 사용한다.

- host: `localhost` 또는 `127.0.0.1`
- port: `55432`
- database: `persistence_lab`
- username: `lab_user`
- image: `postgres:17.6-alpine`

Compose DB는 official EXP-001 database target이다. Testcontainers는 automated test 용도로만 유지하며 official timing target으로 사용하지 않는다.

각 warm-up과 official run은 비어 있는 `benchmark_record` table에서 시작한다. Reset은 timing boundary 밖에서 수행한다.

허용되는 reset command:

```sql
TRUNCATE TABLE benchmark_record RESTART IDENTITY;
```

Reset은 모든 safety gate가 통과한 경우에만 허용한다.

Configuration gate:

- active profile이 `exp001`
- `lab.experiment.allow-destructive-reset=true`
- configured host가 `localhost` 또는 `127.0.0.1`
- configured port가 `55432`
- configured database가 `persistence_lab`
- configured username이 `lab_user`

Actual JDBC connection gate:

- `current_database()`가 `persistence_lab`를 반환
- `current_user`가 `lab_user`를 반환
- server version query 성공
- JDBC metadata URL이 loopback target을 가리킴
- connection이 read-only가 아님

Configured value 또는 actual connection identity 중 하나라도 다르면 reset과 official execution을 중단한다.

## 실행 환경 안정화

Official execution 전 자동 확인 항목:

- clean working tree
- current branch와 Git SHA
- Java version
- Gradle version
- Docker version
- PostgreSQL server version
- OS
- CPU
- memory snapshot
- disk free space
- sanitized JDBC URL
- active Spring profile
- SQL logging disabled
- Hibernate statistics disabled
- effective JDBC batch size
- effective Hikari settings
- effective transaction isolation

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
| Java | Gradle toolchain `21`; runtime version 기록 |
| Spring Boot | `3.5.16` |
| Gradle Wrapper | `8.14.4` |
| Gradle execution | `--no-daemon --max-workers=1` 사용 |
| Benchmark JVM heap | forked JVM에 `-Xms2g -Xmx2g` 적용 |
| Benchmark JVM GC | forked JVM에 `-XX:+UseG1GC` 적용; 실제 GC 기록 |
| Timezone | forked JVM에 `-Duser.timezone=UTC` 적용 |
| PostgreSQL image | `postgres:17.6-alpine`; server version 기록 |
| Git revision | clean `main` HEAD SHA 기록 |
| JPA ID strategy | `GenerationType.IDENTITY` |
| Hibernate batch size | `not configured` |
| Hibernate `order_inserts` | `not configured` |
| JDBC batch size | default `1000`; effective value 기록 |
| `rewriteBatchedInserts` | `not configured` |
| Hikari `maximumPoolSize` | EXP-001 profile에서 `4`로 고정 |
| Hikari `minimumIdle` | EXP-001 profile에서 `1`로 고정 |
| Hikari connection timeout | EXP-001 profile에서 `30000ms`로 고정 |
| auto-commit | effective value 기록 |
| transaction isolation | effective value 기록; expected `READ_COMMITTED` |
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

Invalid reason은 다음으로 분류한다.

- `SYSTEM_ERROR`
- `CONSISTENCY_FAILURE`

상세 reason은 raw run record에 남긴다.

Invalid run은 raw results에 보존하고 representative statistics에서 제외하며 삭제하거나 성공 run으로 덮어쓰지 않는다. 한 round에서 JPA 또는 JDBC 중 하나라도 invalid이면 해당 round는 paired comparison에서 제외한다.

## 지표와 통계(Metrics And Statistics)

Raw metrics:

- `runId`
- `path`
- `round`
- `orderPosition`
- `warmup`
- `valid`
- `invalidReasonType`
- `invalidReason`
- `inputCount`
- `elapsedNanos`
- `elapsedMillis`
- `elapsedSeconds`
- `rowsPerSecond`
- `savedCount`
- `rowCount`
- `checksum`
- `timestamp`
- `gitSha`

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
- time reduction과 speedup은 반올림 전 median value로 계산
- 반올림은 표시 단계에서만 수행
- elapsed milliseconds는 소수 3자리로 표시
- elapsed seconds는 소수 6자리로 표시
- rows per second는 소수 2자리로 표시
- percentage는 소수 2자리로 표시
- denominator가 `0`이면 `null` 출력

## Timing과 Profiling 경계

EXP-001은 timing + consistency only로 수행한다.

Official timing run 중에는 CPU profiling, sampled allocation profiling, JFR, heap dump collection을 실행하지 않는다.

Profiler 작업이 나중에 필요하면 별도 experiment 또는 subphase로 분리하고 별도 결과로 남긴다. Profiler output은 official timing representative data로 사용하지 않는다.

Profiler HTML, raw stack traces, JFR files, heap dumps, large logs, DB dumps는 commit하지 않는다.

## 결과 구조(Result Structure)

이 프로토콜 문서는 result file을 생성하지 않는다.

향후 runner output은 다음 구조를 사용한다.

- run ID: UTC `yyyyMMdd'T'HHmmssSSS'Z'-<shortGitSha>`
- directory: `results/exp-001/<run-id>/`
- `environment.json`
- `timings.csv`
- `consistency.json`
- `summary.md`

Run ID에는 user name, host-specific absolute path, secret을 포함하지 않는다.

## 재현 명령(Reproduction Commands)

다음 명령은 runner 구현 PR이 `main`에 병합된 뒤 사용할 placeholder이다. `docs/exp-001-protocol` branch는 공식 benchmark 실행 branch가 아니다.

```powershell
git switch main
git pull --ff-only origin main
git status --short --branch
docker compose up -d
docker inspect --format '{{.State.Health.Status}}' spring-persistence-performance-lab-postgres
.\gradlew.bat --no-daemon --max-workers=1 clean build
.\gradlew.bat --no-daemon --max-workers=1 runExp001 --args="--spring.profiles.active=exp001 --lab.experiment.allow-destructive-reset=true"
git status --short --branch
docker compose down
```

Official execution 직전 working tree가 dirty이면 run을 중단한다.

## Historical Baseline 정책

다음 label은 분리해서 유지한다.

- Historical baseline
- Public reproduction

기존 private measurement는 public reproduction result가 아니다. Public result가 historical baseline과 다르면 어느 한쪽을 덮어쓰지 않는다. 차이는 environment, configuration 또는 implementation difference로 분석한다.
