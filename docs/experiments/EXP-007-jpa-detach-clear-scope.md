# EXP-007: JPA detach/clear scope 관찰

상태: focused integration test `VERIFIED`.

## 실험 질문

연관관계가 없는 두 `BenchmarkRecord`가 managed 상태일 때 `detach(first)`는 first만 persistence context에서 제외하고 second는 managed 상태로 유지하지만, 이후 `clear()`는 second도 제외하는가?

## 가설

같은 transaction과 같은 `EntityManager` 안에서 두 `BenchmarkRecord`를 `persist()`하고 `flush()`한 뒤 `EntityManager.detach(first)`를 호출하면 first instance에 대한 `EntityManager.contains(first)`는 `false`, second instance에 대한 `contains(second)`는 `true`를 반환할 것으로 예상한다. 이어서 `EntityManager.clear()`를 호출하면 second instance도 persistence context에서 제외되어 `contains(second)`가 `false`를 반환할 것으로 예상한다.

## EXP-005/006과의 연결

- EXP-005는 같은 transaction의 같은 entity instance에서 `persist()` 직후와 `flush()` 직후 managed 상태가 유지되고, `clear()` 후 detached 상태가 되는 것을 확인했다.
- EXP-006은 `clear()` 이후 같은 ID를 `find()`했을 때 original instance는 detached 상태로 남고, reloaded instance가 managed 상태가 되는 것을 확인했다.
- EXP-007은 `find()`나 object identity가 아니라 두 managed instance 중 하나만 `detach(entity)`했을 때의 범위와 이후 `clear()`의 범위를 비교한다.

## 기존 실험과 겹치지 않는 이유

EXP-005는 단일 instance에 대한 `clear()` 결과만 관찰했고, EXP-006은 `clear()` 이후 재조회 instance identity를 관찰했다. 이번 실험은 두 instance를 동시에 managed 상태로 둔 뒤 `detach(first)`가 first와 second에 서로 다른 상태를 남기는지 확인한다. 따라서 `contains()`를 직접 지표로 쓰지만, 기존 실험의 `clear()` 또는 `find()` 관찰을 API 이름만 바꿔 반복하지 않는다.

## 실험 범위

- 현재 production `BenchmarkRecord`처럼 연관관계가 없는 entity instance의 직접 상태만 관찰한다.
- lifecycle 상태 지표는 `EntityManager.contains(entity)`만 사용한다.
- transaction commit 후 저장 건수, key 및 저장 필드 정합성을 기존 `ConsistencyVerifier`로 확인한다.
- SQL 실행 시점, cache hit, persistence context 내부 크기, memory, chunk 처리, 성능은 판정하지 않는다.

## 고정 조건

| 항목 | 값 |
|---|---|
| 실험 성격 | focused integration test |
| DB | Testcontainers PostgreSQL `postgres:17.6-alpine` |
| test class | `com.example.persistencebenchmark.JpaDetachClearScopeIntegrationTest` |
| entity | production `BenchmarkRecord` |
| table | production Flyway migration의 `benchmark_record` |
| entity ID strategy | production `GenerationType.IDENTITY` |
| input count | `2` |
| transaction boundary | test method가 아니라 `TransactionTemplate` |
| direct lifecycle metric | `EntityManager.contains(entity)` |
| official benchmark | `NOT_RUN` |
| profiler/JFR | `NOT_APPLIED` |

## transaction 경계

- test method에는 `@Transactional`을 붙이지 않는다.
- `TransactionTemplate` 안에서 deterministic command 2건으로 first와 second `BenchmarkRecord` instance를 만든다.
- 같은 transaction과 같은 `EntityManager`, 같은 first/second instance에서 `persist()`, `flush()`, `detach(first)`, `clear()` 직후의 `contains()` 값을 기록한다.
- transaction 반환 후 lifecycle 관찰값을 assertion한다.
- transaction commit 후 기존 `ConsistencyVerifier`로 저장 결과 정합성을 확인한다.

## entity와 입력 조건

- entity는 production `BenchmarkRecord`를 그대로 사용한다.
- schema는 production Flyway migration의 `benchmark_record` table을 그대로 사용한다.
- 입력은 `BenchmarkRecordCommandGenerator.generate(2)`가 생성한 deterministic command 2건이다.
- 두 command는 서로 다른 `businessKey`를 가진다.

## 관찰 순서

1. 서로 다른 deterministic command로 first와 second entity를 생성한다.
2. `entityManager.persist(first)`를 호출한다.
3. `entityManager.persist(second)`를 호출한다.
4. persist 직후 first와 second의 `contains()` 값을 기록한다.
5. `entityManager.flush()`를 호출한다.
6. flush 직후 first와 second의 `contains()` 값을 기록한다.
7. `entityManager.detach(first)`를 호출한다.
8. detach 직후 first와 second의 `contains()` 값을 기록한다.
9. `entityManager.clear()`를 호출한다.
10. clear 직후 first와 second의 `contains()` 값을 기록한다.
11. processed command count `2`를 기록한다.
12. 작은 immutable observation record를 transaction 밖으로 반환한다.

## 실제 관찰값

실행:

- base HEAD: `f425fe34c7b3482f9e60855249fb0f1c7a6ad574`
- branch: `experiment/jpa-detach-clear-scope-observation`
- execution tree state: EXP-007 test와 문서가 untracked working-tree files로 존재
- focused test command: `.\gradlew.bat --no-daemon test --rerun-tasks --tests "com.example.persistencebenchmark.JpaDetachClearScopeIntegrationTest"`
- started at UTC: `2026-08-08T11:08:02.6809031Z`
- ended at UTC: `2026-08-08T11:08:40.3569864Z`
- native exit code: `0`

Focused integration test 관찰값:

- after `persist()`:
  - first managed: `true`
  - second managed: `true`
- after `flush()`:
  - first managed: `true`
  - second managed: `true`
- after `detach(first)`:
  - first managed: `false`
  - second managed: `true`
- after `clear()`:
  - first managed: `false`
  - second managed: `false`
- processed command count: `2`

## 정합성 결과

- focused integration test: `VERIFIED PASS`
- `ConsistencyReport.hasFailures()`: `false`
- row count: `VERIFIED`, expected command count와 일치
- distinct business key count: `VERIFIED`, expected business key count와 일치
- missing business keys: `VERIFIED`, empty
- unexpected business keys: `VERIFIED`, empty
- duplicate business keys: `VERIFIED`, empty
- normalized snapshot checksum: `VERIFIED`, 입력 2건과 일치

## runtime evidence identity

- test source: `src/test/java/com/example/persistencebenchmark/JpaDetachClearScopeIntegrationTest.java`
- test source raw SHA-256 before execution: `27e16593c3a04eb0cbf767d50dcf21fb43b8e9c9e41dd9add1d765f985b2f39a`
- prospective Git blob ID: `edd0b743d9c2ae7db3a099e1c98f26ec2bd798a9`
- canonical blob SHA-256: `27e16593c3a04eb0cbf767d50dcf21fb43b8e9c9e41dd9add1d765f985b2f39a`
- source line ending: LF-only
- test source raw SHA-256 after execution: `27e16593c3a04eb0cbf767d50dcf21fb43b8e9c9e41dd9add1d765f985b2f39a`
- test source hash unchanged after execution: `true`
- XML result: `build/test-results/test/TEST-com.example.persistencebenchmark.JpaDetachClearScopeIntegrationTest.xml`
- XML last write UTC: `2026-08-08T11:08:35.6896824Z`
- XML class: `com.example.persistencebenchmark.JpaDetachClearScopeIntegrationTest`
- XML tests: `1`
- XML failures: `0`
- XML errors: `0`
- XML skipped: `0`

Lifecycle boolean 값은 XML에 직접 출력된 값이 아니다. Evidence는 위 SHA-256으로 식별한 finalized test source의 exact assertions와 focused XML PASS의 결합으로 확인한다.

## 판정

현재 판정: `VERIFIED_LOCAL`.

같은 transaction의 같은 `EntityManager` 안에서 연관관계가 없는 두 `BenchmarkRecord` instance를 `persist()`하고 `flush()`한 뒤 `detach(first)`를 호출했을 때 first는 detached 상태가 되었고 second는 managed 상태를 유지했다. 이어서 `clear()`를 호출하면 second도 detached 상태가 되었다. transaction commit 후 저장 정합성도 통과했다.

Result code: `PERSISTENCE_LAB_DETACH_CLEAR_SCOPE_VERIFIED_LOCALLY`.

## 해석

이번 local runtime 관찰에서는 `detach(first)`와 `clear()`의 범위 차이가 `EntityManager.contains(entity)` 값으로 구분되었다. `detach(first)` 직후 first와 second의 상태가 달랐고, `clear()` 직후에는 남아 있던 second도 persistence context에 포함되지 않았다.

이 해석은 현재 production `BenchmarkRecord`처럼 연관관계가 없는 두 instance의 직접 상태 관찰에 한정한다.

## 한계

- 현재 연관관계가 없는 production `BenchmarkRecord` 두 instance의 local runtime 관찰에 한정된다.
- cascade `DETACH` 또는 연관관계 entity 동작을 검증하지 않는다.
- `detach(entity)`가 모든 모델에서 항상 오직 한 객체에만 영향을 준다는 일반 계약으로 확장하지 않는다.
- `clear()`가 database row를 삭제한다는 결론이 아니다.
- SQL 실행 횟수나 정확한 시점을 판정하지 않는다.
- cache hit, JDBC batching, memory 회수, chunk 처리, 성능 향상을 판정하지 않는다.
- production service에 `detach()` 또는 `clear()`를 추가해야 한다는 결론이 아니다.
- Hibernate 내부 구현 원인을 분석하지 않는다.
- 50,000건 benchmark, profiler/JFR은 실행하지 않는다.

## 다루지 않은 범위

- cascade `DETACH`
- 연관관계 entity lifecycle
- detached entity의 `merge()` 반환 instance
- chunk 단위 `flush()/clear()`
- persistence context 내부 collection 크기 또는 memory 사용량
- SQL 실행 시점, SQL 횟수, cache hit
- JDBC batching, PostgreSQL JDBC driver rewrite
- production ID 전략, schema, config 변경
- 50,000건 성능
- profiler/JFR 기반 원인 분석

## 다음 질문

`detach(first)`와 `clear()`의 범위 차이가 현재 두 `BenchmarkRecord` instance에서 확인되면, detached entity를 `merge()`할 때 original instance와 반환 instance의 managed 상태를 별도 focused experiment로 분리할 필요가 있는가?
