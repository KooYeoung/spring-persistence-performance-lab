# EXP-003: JPA SEQUENCE INSERT Batching 관찰

상태: focused integration test `VERIFIED`.

## 질문

`GenerationType.SEQUENCE`를 사용하는 test-only entity 5건 INSERT에서 `hibernate.jdbc.batch_size=5`를 설정하면 Hibernate가 실제 JDBC batch를 실행하는가?

## 가설

EXP-002에서는 production `BenchmarkRecord`의 `GenerationType.IDENTITY` 때문에 `hibernate.jdbc.batch_size=5` 설정이 있어도 save 구간의 Hibernate session metrics가 `0 JDBC batches`를 보고했다. 이번 실험에서는 production entity를 변경하지 않고 test-only `SEQUENCE` entity를 별도로 두면 같은 batch size 조건에서 INSERT JDBC batch가 관찰될 것으로 예상한다.

## EXP-002와의 연결

EXP-002의 결론은 `IDENTITY` 전략에서 INSERT batching이 비활성화되는지에 한정된다. EXP-003은 ID 전략만 `SEQUENCE`로 바꾼 test-only 관찰 실험으로, `IDENTITY` 결론의 비교 기준을 보강한다.

## 조건

| 항목 | 값 |
|---|---|
| 실험 성격 | focused integration test |
| DB | Testcontainers PostgreSQL `postgres:17.6-alpine` |
| 저장 경로 | test method의 `EntityManager.persist()` |
| entity | test-only `SequenceBatchRecord` |
| table | test-only `sequence_batch_record` |
| sequence | test-only `sequence_batch_record_seq` |
| entity ID strategy | `GenerationType.SEQUENCE` |
| sequence allocation size | `1` |
| input count | `5` |
| configured Hibernate JDBC batch size | `5` |
| Hibernate statistics | `enabled` |
| SQL logging | `DEBUG` |
| JDBC batch logger | `org.hibernate.orm.jdbc.batch=TRACE` |
| official benchmark | `NOT_RUN` |
| profiler/JFR | `NOT_APPLIED` |

## test-only 격리 구조

- production `BenchmarkRecord`와 production Flyway migration은 변경하지 않는다.
- `ApplicationContextInitializer`가 Hibernate `validate` 전에 `sequence_batch_record_seq`와 `sequence_batch_record`를 생성한다.
- `@EntityScan`은 production `BenchmarkRecord`와 test-only `SequenceBatchRecord`를 함께 보게 한다.
- 저장은 `@Transactional` test method가 아니라 `TransactionTemplate` 안에서 수행하고, `persist()` 5회 후 `flush()`한다.
- production `ConsistencyVerifier`는 `benchmark_record` 전용이므로 `sequence_batch_record` 정합성은 `JdbcTemplate` 조회로 직접 확인한다.

## 실행 명령

Java test compilation:

```powershell
.\gradlew.bat --no-daemon compileTestJava
```

Focused integration test:

```powershell
.\gradlew.bat --no-daemon test --tests "com.example.persistencebenchmark.JpaSequenceInsertBatchingIntegrationTest"
```

전체 test suite, EXP-001 official benchmark, profiler/JFR, `rewriteBatchedInserts`, production `SEQUENCE` 전환 실험은 포함하지 않는다.

## 실제 관찰값

실행:

- branch: `experiment/jpa-sequence-batching-observation`
- production source revision: `c5d5ac38f2c48c36f97cc63a0b148b266e73d78f`
- execution tree state: EXP-003 test와 문서가 untracked working tree files로 존재
- executed test file SHA-256: `D3436D5BF12C55D81BE9B9EC2C5B2A919983A70C9D84AB32EB276D25A4380B23`
- final execution UTC: `2026-08-05T16:22:55Z`
- compile command: `.\gradlew.bat --no-daemon compileTestJava`
- compile native exit code: `0`
- focused test command: `.\gradlew.bat --no-daemon test --tests "com.example.persistencebenchmark.JpaSequenceInsertBatchingIntegrationTest"`
- first focused test native exit code: `1`
- final focused test native exit code: `0`

첫 focused runtime 실행은 save 동작까지 도달하지 못했다. 원인은 test-only schema DDL이 Flyway보다 먼저 실행되어 Flyway가 `Found non-empty schema(s) "public" but no schema history table` 오류로 context 초기화를 중단한 것이다. 수정 후 `ApplicationContextInitializer`는 test-only `FlywayMigrationStrategy`를 등록하고, 해당 strategy가 Flyway migration 이후와 Hibernate validate 이전에 test-only sequence/table을 생성한다.

Focused integration test 관찰값:

- effective Hibernate JDBC batch size: `5`
- Hibernate statistics enabled: `true`
- `savedCount`: `5`
- Hibernate `entityInsertCount`: `5`
- Hibernate `prepareStatementCount`: `> 0`
- save 구간 SQL log: `select nextval('sequence_batch_record_seq')` 5회
- save 구간 SQL log: `insert into sequence_batch_record ... values (?,?,?,?,?,?)` 5회
- save 구간 session metrics: `6 JDBC statements` prepared
- save 구간 session metrics: `5 JDBC statements` executed
- save 구간 session metrics: `1 JDBC batches` executed

`entityInsertCount`, `prepareStatementCount`, SQL 로그만으로 JDBC batch 사용을 결론내리지 않는다. batch 여부는 save 구간의 Hibernate session metrics에 있는 `spent executing N JDBC batches` 값으로만 판정한다.

## 정합성 결과

- focused integration test: `VERIFIED PASS`
- row count: `VERIFIED`, `5`
- distinct business key count: `VERIFIED`, `5`
- saved `business_key`: `VERIFIED`, 입력 5건과 일치
- saved `name`: `VERIFIED`, 입력 5건과 일치
- saved `numeric_value`: `VERIFIED`, 입력 5건과 일치
- saved `occurred_on`: `VERIFIED`, 입력 5건과 일치

## 판정

현재 판정: `VERIFIED_LOCAL`.

Local runtime save 구간에서 `1 JDBC batches`가 직접 관찰되었고, test-only table 정합성이 통과했다.

Result code: `PERSISTENCE_LAB_SEQUENCE_BATCHING_VERIFIED_LOCALLY`.

## 한계

- production `BenchmarkRecord`를 `SEQUENCE`로 변경한 실험이 아니다.
- 50,000건 성능 비교가 아니다.
- Testcontainers 기반 focused integration test이며 EXP-001 official benchmark 결과가 아니다.
- profiler/JFR은 사용하지 않는다.
- `rewriteBatchedInserts` 동작은 검증하지 않는다.
- production 성능으로 일반화할 수 없다.
- sequence `allocationSize=1` 조건에 한정되며 pooled optimizer는 비교하지 않는다.
- Hibernate session metrics 형식이 바뀌어 batch count를 파싱할 수 없으면 evidence 부족으로 실패 처리한다.

## 다음 질문

test-only `SEQUENCE`에서 JDBC batch가 관찰된다면 production 모델의 ID 전략 변경이 정합성, migration, 성능에 어떤 비용과 이득을 만드는지 별도 Issue에서 검토할 필요가 있는가?
