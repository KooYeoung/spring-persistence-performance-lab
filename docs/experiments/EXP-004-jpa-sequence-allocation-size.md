# EXP-004: JPA SEQUENCE allocationSize 관찰

상태: focused integration test `VERIFIED`.

## 질문

`GenerationType.SEQUENCE`를 사용하는 test-only entity 5건 INSERT에서 `@SequenceGenerator(allocationSize=1)`과 `allocationSize=5`는 sequence 값 조회 횟수와 JDBC batch 실행 관찰값을 어떻게 바꾸는가?

## 가설

EXP-003에서는 `allocationSize=1` 조건에서 5건 저장 시 `select nextval('sequence_batch_record_seq')` 5회와 `1 JDBC batches`를 관찰했다. 이번 실험에서는 같은 input count와 `hibernate.jdbc.batch_size=5` 조건에서 `allocationSize=5`를 사용하는 별도 test-only entity가 더 적은 sequence 값 조회로 5건의 ID를 할당하고, INSERT JDBC batch는 계속 관찰될 것으로 예상한다.

## EXP-002, EXP-003과의 연결

- EXP-002는 production `BenchmarkRecord`의 `GenerationType.IDENTITY` 조건에서 save 구간 `0 JDBC batches`를 관찰했다.
- EXP-003은 production entity를 변경하지 않고 test-only `GenerationType.SEQUENCE`, `allocationSize=1` 조건에서 save 구간 `1 JDBC batches`를 관찰했다.
- EXP-004는 `SEQUENCE` 안에서 `allocationSize`만 바꿔 sequence 값 조회 횟수를 비교한다.

## 조건

| 항목 | 값 |
|---|---|
| 실험 성격 | focused integration test |
| DB | Testcontainers PostgreSQL `postgres:17.6-alpine` |
| 저장 경로 | test method의 `EntityManager.persist()` |
| test class | `com.example.persistenceallocation.JpaSequenceAllocationSizeIntegrationTest` |
| entity | test-only `AllocationOneRecord`, `AllocationFiveRecord` |
| table | test-only `sequence_allocation_one_record`, `sequence_allocation_five_record` |
| sequence | test-only `sequence_allocation_one_record_seq`, `sequence_allocation_five_record_seq` |
| entity ID strategy | `GenerationType.SEQUENCE` |
| compared sequence allocation size | `1`, `5` |
| input count | `5` |
| configured Hibernate JDBC batch size | `5` |
| Hibernate statistics | `enabled` |
| SQL logging | `DEBUG` |
| JDBC batch logger | `org.hibernate.orm.jdbc.batch=TRACE` |
| official benchmark | `NOT_RUN` |
| profiler/JFR | `NOT_APPLIED` |

## test-only 격리 구조

- production `BenchmarkRecord`, production Flyway migration, application 기본 설정은 변경하지 않는다.
- EXP-004 test class와 test-only entities는 application root package 밖의 `com.example.persistenceallocation` package에 둔다.
- `ApplicationContextInitializer`가 test-only `FlywayMigrationStrategy`를 등록한다.
- test-only `FlywayMigrationStrategy`는 production Flyway migration 이후와 Hibernate `validate` 이전에 EXP-004 table과 sequence를 생성한다.
- `@EntityScan`은 production `BenchmarkRecord`와 EXP-004 test-only entities를 함께 보게 한다.
- 저장은 `@Transactional` test method가 아니라 `TransactionTemplate` 안에서 수행하고, `persist()` 5회 후 `flush()`한다.
- production `ConsistencyVerifier`는 `benchmark_record` 전용이므로 EXP-004 test-only tables 정합성은 `JdbcTemplate` 조회로 직접 확인한다.

## 실행 명령

Java test compilation:

```powershell
.\gradlew.bat --no-daemon compileTestJava
```

Focused integration test:

```powershell
.\gradlew.bat --no-daemon test --tests "com.example.persistenceallocation.JpaSequenceAllocationSizeIntegrationTest"
```

전체 test suite, EXP-001 official benchmark, profiler/JFR, `rewriteBatchedInserts`, production `SEQUENCE` 전환 실험은 포함하지 않는다.

## 실제 관찰값

실행:

- branch: `experiment/jpa-sequence-allocation-size-observation`
- production source revision: `21c8ef5d50603092bc4eeb81e4a1ac601ce52883`
- execution tree state: EXP-004 test와 문서가 untracked working tree files로 존재
- executed test file SHA-256: `0714A1CC99D255FD5AE5FC7E6DEF798FF671DF9CF21ADB8EB27AF015A084364E`
- final execution UTC: `2026-08-05T17:36:05Z`
- compile command: `.\gradlew.bat --no-daemon compileTestJava`
- compile native exit code: `0`
- focused test command: `.\gradlew.bat --no-daemon test --tests "com.example.persistenceallocation.JpaSequenceAllocationSizeIntegrationTest"`
- first focused test native exit code: `1`
- final focused test native exit code: `0`

첫 focused runtime 실행은 save 동작까지 도달하지 못했다. 원인은 EXP-004 test-only entities를 `com.example.persistencebenchmark` package에 두어 package 단위 `@EntityScan`이 EXP-003의 test-only `SequenceBatchRecord`까지 함께 스캔했고, 현재 context에는 `sequence_batch_record` schema가 없어 Hibernate `validate`가 중단한 것이다. 수정 후 EXP-004 test-only entities는 application root package 밖의 `com.example.persistenceallocation` package에 둔다.

Focused integration test 관찰값:

- effective Hibernate JDBC batch size: `5`
- Hibernate statistics enabled: `true`
- `allocationSize=1` saved count: `5`
- `allocationSize=1` Hibernate `entityInsertCount`: `5`
- `allocationSize=1` Hibernate `prepareStatementCount`: `> 0`
- `allocationSize=1` save 구간 SQL log: `select nextval('sequence_allocation_one_record_seq')` 5회
- `allocationSize=1` save 구간 SQL log: `insert into sequence_allocation_one_record ... values (?,?,?,?,?,?)` 5회
- `allocationSize=1` save 구간 session metrics: `6 JDBC statements` prepared
- `allocationSize=1` save 구간 session metrics: `5 JDBC statements` executed
- `allocationSize=1` save 구간 session metrics: `1 JDBC batches` executed
- `allocationSize=5` saved count: `5`
- `allocationSize=5` Hibernate `entityInsertCount`: `5`
- `allocationSize=5` Hibernate `prepareStatementCount`: `> 0`
- `allocationSize=5` save 구간 SQL log: `select nextval('sequence_allocation_five_record_seq')` 2회
- `allocationSize=5` save 구간 SQL log: `insert into sequence_allocation_five_record ... values (?,?,?,?,?,?)` 5회
- `allocationSize=5` save 구간 session metrics: `3 JDBC statements` prepared
- `allocationSize=5` save 구간 session metrics: `2 JDBC statements` executed
- `allocationSize=5` save 구간 session metrics: `1 JDBC batches` executed

`entityInsertCount`, `prepareStatementCount`, SQL INSERT 로그만으로 JDBC batch 사용을 결론내리지 않는다. batch 여부는 save 구간의 Hibernate session metrics에 있는 `spent executing N JDBC batches` 값으로만 판정한다. sequence 값 조회 횟수는 각 save 구간 SQL log의 `select nextval('<sequence_name>')` 횟수로만 판정한다.

## 정합성 결과

- focused integration test: `VERIFIED PASS`
- `sequence_allocation_one_record` row count: `VERIFIED`, `5`
- `sequence_allocation_one_record` distinct business key count: `VERIFIED`, `5`
- `sequence_allocation_one_record` saved `business_key`: `VERIFIED`, 입력 5건과 일치
- `sequence_allocation_one_record` saved `name`: `VERIFIED`, 입력 5건과 일치
- `sequence_allocation_one_record` saved `numeric_value`: `VERIFIED`, 입력 5건과 일치
- `sequence_allocation_one_record` saved `occurred_on`: `VERIFIED`, 입력 5건과 일치
- `sequence_allocation_five_record` row count: `VERIFIED`, `5`
- `sequence_allocation_five_record` distinct business key count: `VERIFIED`, `5`
- `sequence_allocation_five_record` saved `business_key`: `VERIFIED`, 입력 5건과 일치
- `sequence_allocation_five_record` saved `name`: `VERIFIED`, 입력 5건과 일치
- `sequence_allocation_five_record` saved `numeric_value`: `VERIFIED`, 입력 5건과 일치
- `sequence_allocation_five_record` saved `occurred_on`: `VERIFIED`, 입력 5건과 일치

## 판정

현재 판정: `VERIFIED_LOCAL`.

Local runtime save 구간에서 `allocationSize=1`은 sequence 값 조회 5회와 `1 JDBC batches`, `allocationSize=5`는 sequence 값 조회 2회와 `1 JDBC batches`가 직접 관찰되었다. 두 test-only table의 정합성도 통과했다.

Result code: `PERSISTENCE_LAB_SEQUENCE_ALLOCATION_SIZE_VERIFIED_LOCALLY`.

## 한계

- production `BenchmarkRecord`를 `SEQUENCE`로 변경한 실험이 아니다.
- production sequence 또는 production migration 정책을 검증한 실험이 아니다.
- 50,000건 성능 비교가 아니다.
- Testcontainers 기반 focused integration test이며 EXP-001 official benchmark 결과가 아니다.
- profiler/JFR은 사용하지 않는다.
- `rewriteBatchedInserts` 동작은 검증하지 않는다.
- production 성능으로 일반화할 수 없다.
- `allocationSize=1`과 `allocationSize=5`의 5건 저장 관찰에 한정된다.
- `allocationSize=5`에서 sequence 값 조회가 왜 2회로 관찰되는지에 대한 Hibernate optimizer 내부 원인 분석은 이 실험의 판정 범위가 아니다.
- Hibernate SQL log 또는 session metrics 형식이 바뀌어 sequence fetch count나 batch count를 파싱할 수 없으면 evidence 부족으로 실패 처리한다.

## 다음 질문

`allocationSize`가 sequence 조회 횟수를 줄이는 것이 확인되면, production 모델에서 ID 전략을 바꾸기 전에 migration 비용, ID gap 허용 정책, 실제 50,000건 성능 영향 중 무엇을 먼저 검토해야 하는가?
