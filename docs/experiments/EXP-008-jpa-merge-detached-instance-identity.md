# EXP-008: JPA merge detached instance identity 관찰

상태: focused integration test `VERIFIED`.

## 1. 실험 질문

Detached 상태의 original entity를 `EntityManager.merge(original)`에 전달하면 original 자체가 다시 managed 상태가 되는가, 아니면 별도의 returned instance가 managed 상태가 되는가?

## 2. 가설

- `merge(original)` 후 original은 detached 상태로 남는다.
- `merge()`가 반환한 instance만 managed 상태다.
- original과 returned instance는 서로 다른 Java object다.
- 두 instance는 같은 ID와 저장 필드를 가진다.
- transaction commit 후 `benchmark_record` row 정합성이 유지된다.

## 3. EXP-005~007과의 연결

- EXP-005는 `persist()`와 `flush()` 후 같은 instance가 managed 상태이고 `clear()` 후 detached 상태가 되는지 확인했다.
- EXP-006은 `clear()` 후 같은 ID를 `find()`하면 original은 detached로 남고 다른 managed instance가 반환되는지 확인했다.
- EXP-007은 `detach(first)`와 `clear()`의 범위 차이를 `contains()`로 확인했다.
- EXP-008은 EXP-007의 다음 질문인 detached entity의 `merge()` 반환 instance identity를 별도 focused experiment로 분리한다.

## 4. EXP-006 `find()` identity와 다른 점

EXP-006은 ID로 row를 다시 조회하는 `find()`를 사용했다. EXP-008은 detached original instance 자체를 `merge(original)`에 전달하고, original과 returned instance의 managed 상태와 object identity를 비교한다.

## 5. 실험 범위

- production `BenchmarkRecord` 1건만 사용한다.
- lifecycle 상태는 `EntityManager.contains()`로만 관찰한다.
- object identity는 `original == merged`로만 관찰한다.
- row identity는 ID와 저장 필드 equality로 구분한다.
- commit 후 정합성은 기존 `ConsistencyVerifier`로 확인한다.

## 6. 고정 조건

| 항목 | 값 |
|---|---|
| 실험 성격 | focused integration test |
| DB | Testcontainers PostgreSQL `postgres:17.6-alpine` |
| test class | `com.example.persistencebenchmark.JpaMergeDetachedInstanceIdentityIntegrationTest` |
| entity | production `BenchmarkRecord` |
| table | production Flyway migration의 `benchmark_record` |
| entity ID strategy | production `GenerationType.IDENTITY` |
| input count | `1` |
| transaction boundary | test method가 아니라 `TransactionTemplate` |
| entity scan | `@EntityScan(basePackageClasses = BenchmarkRecord.class)` |
| official benchmark | `NOT_RUN` |
| profiler/JFR | `NOT_APPLIED` |

## 7. 변경 변수

`clear()`로 detached 상태가 된 original instance를 `EntityManager.merge(original)`에 전달한다. 그 직후 original과 returned instance의 managed 상태, Java object identity, ID와 저장 필드 equality를 기록한다.

## 8. transaction 경계

test method에는 `@Transactional`을 붙이지 않는다. `TransactionTemplate.execute(...)` callback 안에서 command 생성, entity 생성, `persist()`, `flush()`, `clear()`, `merge()` 관찰을 모두 수행한다. callback 정상 반환으로 transaction commit이 끝난 뒤 기존 `verifyExpected(commands)`로 database 정합성을 확인한다.

## 9. entity와 입력 조건

- entity는 production `BenchmarkRecord`를 그대로 사용한다.
- schema는 production Flyway migration의 `benchmark_record` table을 그대로 사용한다.
- 입력은 `generatedCommands(1)`이 생성한 deterministic command 1건이다.
- `BenchmarkRecord.from(command, CREATED_AT)`로 original entity를 만든다.
- `CREATED_AT`은 `2024-01-01T00:00:00Z`로 고정한다.

## 10. 관찰 순서

1. `generatedCommands(1)`에서 command 1건을 준비한다.
2. production factory `BenchmarkRecord.from(command, CREATED_AT)`로 original을 생성한다.
3. `entityManager.persist(original)`을 호출한다.
4. persist 직후 `entityManager.contains(original)`을 기록한다.
5. `entityManager.flush()`를 호출한다.
6. original ID 값을 기록한다.
7. flush 직후 `entityManager.contains(original)`을 기록한다.
8. `entityManager.clear()`를 호출한다.
9. clear 직후 `entityManager.contains(original)`을 기록한다.
10. `BenchmarkRecord merged = entityManager.merge(original)`을 호출한다.
11. merge 직후 original/merged의 managed 상태, `original == merged`, ID와 저장 필드를 기록한다.
12. processed count `1`을 기록한다.
13. callback을 정상 반환한다.
14. transaction commit 후 `verifyExpected(commands)`를 실행한다.

## 11. 실제 관찰값

Lifecycle boolean 값은 XML에 직접 출력된 값이 아니다. Evidence는 runtime evidence identity에 적힌 finalized test source의 exact assertions와 focused XML 성공 결과의 결합으로 확인한다.

- persist 후 original managed: `true`
- flush 후 original managed: `true`
- clear 후 original detached: `true`
- merge 후 original detached 유지: `true`
- merge 반환 instance managed: `true`
- original과 returned는 서로 다른 Java object: `true`
- original ID와 merged ID: non-null이며 equal
- original과 merged 저장 필드 equality: `businessKey`, `name`, `numericValue`, `occurredOn`, `createdAt`
- processed count: `1`

## 12. object identity와 row identity 구분

object identity는 `original == merged` 결과로만 판정한다. 이번 관찰에서 두 instance는 같은 Java object가 아니다. row identity는 generated ID equality와 저장 필드 equality로 판정하며, 이번 관찰에서 두 instance는 같은 ID와 같은 저장 필드 값을 가진다.

## 13. 정합성 결과

- focused integration test: `VERIFIED`
- `ConsistencyReport.hasFailures()`: `false`
- row count: expected command count와 일치
- distinct business key count: row count와 일치
- missing business keys: empty
- unexpected business keys: empty
- duplicate business keys: empty
- normalized snapshot checksum: 입력 1건과 일치

## 14. runtime evidence identity

| 항목 | 값 |
|---|---|
| base HEAD | `f52061d223f3bf3fc5779249ce04764bc80b4dc0` |
| branch | `experiment/jpa-merge-detached-instance-identity-observation` |
| finalized test source path | `src/test/java/com/example/persistencebenchmark/JpaMergeDetachedInstanceIdentityIntegrationTest.java` |
| raw SHA-256 | `ce1fcbcbaf8ed9f57bfc87eff86baa03d08bb82069945252e5897682d414b3ab` |
| prospective Git blob ID | `6c3cb6107de02b9f958f60f502a4481292a847d0` |
| line ending | LF-only |
| CRLF count | `0` |
| LF count | `136` |
| lone CR count | `0` |
| canonical blob byte SHA-256 | `ce1fcbcbaf8ed9f57bfc87eff86baa03d08bb82069945252e5897682d414b3ab` |
| raw/canonical relation | LF-only라 raw checkout byte SHA-256과 canonical blob byte SHA-256이 동일하다. |
| exact focused command | `.\gradlew.bat --no-daemon test --rerun-tasks --tests "com.example.persistencebenchmark.JpaMergeDetachedInstanceIdentityIntegrationTest"` |
| execution count | `1` |
| UTC start | `2026-08-18T14:05:21.7973920Z` |
| UTC end | `2026-08-18T14:05:48.2943161Z` |
| native exit code | `0` |
| XML path | `build/test-results/test/TEST-com.example.persistencebenchmark.JpaMergeDetachedInstanceIdentityIntegrationTest.xml` |
| XML class | `com.example.persistencebenchmark.JpaMergeDetachedInstanceIdentityIntegrationTest` |
| XML tests/failures/errors/skipped | `1` / `0` / `0` / `0` |
| XML timestamp | `2026-08-18T14:05:46.957Z` |
| XML last-write UTC | `2026-08-18T14:05:48.1236410Z` |
| source hash after execution | `ce1fcbcbaf8ed9f57bfc87eff86baa03d08bb82069945252e5897682d414b3ab` |
| source hash unchanged | `true` |
| working-tree boundary | test와 doc는 아직 untracked working-tree files다. |

## 15. 판정

현재 local runtime에서는 detached original을 `merge(original)`에 전달해도 original은 managed 상태가 되지 않았고, `merge()`가 반환한 instance가 managed 상태였다. original과 returned instance는 서로 다른 Java object였지만 같은 generated ID와 저장 필드 값을 가진 같은 row를 나타냈다.

Result code: `PERSISTENCE_LAB_MERGE_DETACHED_INSTANCE_IDENTITY_VERIFIED_LOCALLY`.

## 16. 해석

이번 관찰은 public JPA API인 `EntityManager.contains()`와 `EntityManager.merge()` 반환값 기준으로 original instance와 returned instance의 lifecycle 상태를 분리한다. 이 결과는 현재 production `BenchmarkRecord` 1건과 local PostgreSQL integration test 조건에 한정한다.

## 17. 한계

- `merge()` 내부 구현이나 Hibernate 내부 persistence context 자료구조를 분석하지 않는다.
- SQL 실행 시점이나 SQL 횟수를 판정하지 않는다.
- update SQL 실행 여부와 dirty checking 결과를 판정하지 않는다.
- cache 동작을 판정하지 않는다.
- 모든 JPA provider의 내부 구현으로 일반화하지 않는다.

## 18. 다루지 않은 범위

- merge 전후 필드 수정
- concurrent update
- optimistic locking
- cascade와 association entity
- persistence context size 또는 memory 관찰
- chunk 처리
- performance 측정
- production code, entity, schema, config, dependency 변경

## 19. 다음 질문

Detached original과 `merge()` returned instance의 lifecycle 차이가 확인되면, detached instance의 필드 변경 시점이 `merge()` 전인지 후인지에 따라 database row 변경 관찰을 별도 focused experiment로 분리할 필요가 있는가?
