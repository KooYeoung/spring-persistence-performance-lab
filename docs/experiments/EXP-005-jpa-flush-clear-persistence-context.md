# EXP-005: JPA flush/clear persistence context 관찰

상태: focused integration test `VERIFIED`.

## 질문

같은 transaction에서 `persist()`한 entity는 `flush()` 후에도 managed 상태를 유지하고, `clear()` 후에는 detached 상태가 되는가?

## 가설

`EntityManager.persist(entity)` 직후와 `EntityManager.flush()` 직후에는 같은 entity instance가 persistence context에 남아 있어 `EntityManager.contains(entity)`가 `true`를 반환한다. `EntityManager.clear()` 후에는 persistence context가 비워지므로 같은 entity instance에 대한 `contains()`가 `false`를 반환할 것으로 예상한다.

## EXP-002~004와의 연결

- EXP-002는 production `BenchmarkRecord`의 `GenerationType.IDENTITY` 조건에서 save 구간 `0 JDBC batches`를 관찰했다.
- EXP-003은 test-only `SEQUENCE`, `allocationSize=1` 조건에서 `nextval` 5회와 `1 JDBC batches`를 관찰했다.
- EXP-004는 test-only `SEQUENCE`, `allocationSize=5` 조건에서 현재 runtime 기준 `nextval` 2회와 `1 JDBC batches`를 관찰했다.
- EXP-005는 ID 생성 방식이나 JDBC batch가 아니라 JPA persistence context lifecycle을 작은 관찰값으로 확인한다.

## 실행 조건

| 항목 | 값 |
|---|---|
| 실험 성격 | focused integration test |
| DB | Testcontainers PostgreSQL `postgres:17.6-alpine` |
| test class | `com.example.persistencebenchmark.JpaFlushClearPersistenceContextIntegrationTest` |
| entity | production `BenchmarkRecord` |
| table | production Flyway migration의 `benchmark_record` |
| entity ID strategy | production `GenerationType.IDENTITY` |
| input count | `1` |
| transaction boundary | test method가 아니라 `TransactionTemplate` |
| direct lifecycle metric | `EntityManager.contains(entity)` |
| official benchmark | `NOT_RUN` |
| profiler/JFR | `NOT_APPLIED` |

## Transaction 경계

- test method에는 `@Transactional`을 붙이지 않는다.
- `TransactionTemplate` 안에서 deterministic command 1건으로 `BenchmarkRecord` entity를 만든다.
- 같은 transaction과 같은 entity instance에서 `persist()`, `flush()`, `clear()` 직후의 `contains()` 값을 기록한다.
- transaction 반환 후 lifecycle 관찰값을 assertion한다.
- transaction commit 후 기존 `ConsistencyVerifier`로 저장 결과 정합성을 확인한다.

## 관찰 순서

1. `BenchmarkRecord.from(command, fixedCreatedAt)`으로 entity를 생성한다.
2. `entityManager.persist(entity)`를 호출한 뒤 `contains(entity)`를 기록한다.
3. `entityManager.flush()`를 호출한 뒤 같은 entity instance에 대해 `contains(entity)`를 기록한다.
4. `entityManager.clear()`를 호출한 뒤 같은 entity instance에 대해 `contains(entity)`를 기록한다.
5. transaction 반환 후 세 관찰값과 처리 count를 검증한다.
6. commit 후 저장된 row의 정합성을 검증한다.

## 실제 관찰값

실행:

- branch: `experiment/jpa-flush-clear-persistence-context-observation`
- production source revision: `aa61718f1efaf5dfc89150d69ebc5af84ef8b132`
- execution tree state: EXP-005 test와 문서가 untracked working tree files로 존재
- compile command: `.\gradlew.bat --no-daemon compileTestJava`
- compile native exit code: `0`
- focused test command: `.\gradlew.bat --no-daemon test --tests "com.example.persistencebenchmark.JpaFlushClearPersistenceContextIntegrationTest"`
- first focused test native exit code: `1`
- final focused test native exit code: `0`

첫 focused runtime 실행은 save 동작까지 도달하지 못했다. 원인은 새 테스트가 application root package의 기본 entity scan을 사용하면서 EXP-003 test-only nested entity `SequenceBatchRecord`까지 함께 스캔했고, 현재 context에는 `sequence_batch_record` schema가 없어 Hibernate `validate`가 중단한 것이다. 수정 후 새 테스트는 `@EntityScan(basePackageClasses = BenchmarkRecord.class)`로 production `BenchmarkRecord`만 entity scan 대상에 포함한다.

### PR head 재확인

목적은 committed test source와 runtime PASS의 identity를 연결하는 것이다. 이 재확인은 문서 correction commit 전 PR head에서 수행했고, 이후 correction commit은 EXP-005 문서만 변경하며 test source는 변경하지 않는다.

- run identity: PR head `0657e968a89707dfe05b7c3e7a1f42bca9b58ac0`
- test source: `src/test/java/com/example/persistencebenchmark/JpaFlushClearPersistenceContextIntegrationTest.java`
- test source SHA-256: `2C5A3BE3C89F78EAD5E4961ED6C4A5CAE63892F539CA8AA547BA94448C89A847`
- command: `.\gradlew.bat --no-daemon test --rerun-tasks --tests "com.example.persistencebenchmark.JpaFlushClearPersistenceContextIntegrationTest"`
- started at UTC: `2026-08-06T10:05:23.0146287Z`
- ended at UTC: `2026-08-06T10:05:43.7472181Z`
- native exit code: `0`
- XML result: tests `1`, failures `0`, errors `0`, skipped `0`
- re-confirmed lifecycle assertions: after `persist()` `true`, after `flush()` `true`, after `clear()` `false`, processed count `1`
- re-confirmed consistency assertion: commit 후 `ConsistencyReport.hasFailures()` `false`
- source identity after run: test source SHA-256 unchanged

`contains()` 값은 XML에 직접 출력된 값이 아니라 committed test source의 exact assertion으로 확인한다. XML은 이번 focused test 실행이 PASS였다는 local ignored runtime artifact이며 tracked publication artifact로 다루지 않는다.

Focused integration test 관찰값:

- processed command count: `1`
- after `persist()`: `true`
- after `flush()`: `true`
- after `clear()`: `false`

## 정합성 결과

- focused integration test: `VERIFIED PASS`
- `ConsistencyReport.hasFailures()`: `false`
- row count: `VERIFIED`, expected command count와 일치
- distinct business key count: `VERIFIED`, expected business key count와 일치
- normalized snapshot checksum: `VERIFIED`, 입력 1건과 일치

## 판정

현재 판정: `VERIFIED_LOCAL`.

같은 transaction의 같은 entity instance에서 `persist()` 직후와 `flush()` 직후 `contains(entity)`가 `true`였고, `clear()` 직후 `false`가 관찰되었다. transaction commit 후 저장 정합성도 통과했다.

Result code: `PERSISTENCE_LAB_FLUSH_CLEAR_LIFECYCLE_VERIFIED_LOCALLY`.

## 한계

- `GenerationType.IDENTITY`에서는 `persist()` 시점에 INSERT가 실행될 수 있다. 이 실험은 `flush()`가 INSERT를 발생시킨 정확한 시점을 증명하지 않는다.
- SQL 로그 개수, Hibernate batch metric, `prepareStatementCount`는 판정 근거로 사용하지 않는다.
- persistence context 내부 collection 크기, heap 사용량, 메모리 감소를 측정하지 않는다.
- chunk 단위 `flush()/clear()`나 대량 저장 성능 개선을 검증하지 않는다.
- production service에 `clear()`를 추가해야 한다는 결론이 아니다.
- production entity, production Flyway migration, application 기본 설정은 변경하지 않는다.

## 다음 질문

단일 entity lifecycle이 확인되면, 여러 entity를 일정 단위로 저장할 때 `flush()/clear()`가 chunk 경계의 managed 상태를 어떻게 바꾸는지는 별도 실험으로 분리할 필요가 있는가?
