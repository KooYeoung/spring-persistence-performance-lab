# EXP-009: JPA merge detached state copy 관찰

상태: focused integration test `VERIFIED`.

## 1. 실험 질문

`clear()` 후 detached 상태인 original의 `name`을 변경하고 `EntityManager.merge(original)`을 호출하면, 호출 시점의 변경값이 반환된 managed instance에 복사되고 transaction commit 후 database row에도 반영되는가?

## 2. 가설

- `merge(original)` 후 original은 detached 상태로 남는다.
- `merge()`가 반환한 instance만 managed 상태다.
- original과 returned instance는 서로 다른 Java object다.
- 두 instance는 같은 ID를 가진다.
- `merge()` 호출 시점의 detached original `name` 값이 returned managed instance에 복사된다.
- commit 후 database row도 변경된 `name`을 가진다.

## 3. EXP-005~008과의 연결

- EXP-005는 `persist()`와 `flush()` 후 같은 instance가 managed 상태이고 `clear()` 후 detached 상태가 되는지 확인했다.
- EXP-006은 `clear()` 후 같은 ID를 `find()`하면 original은 detached로 남고 다른 managed instance가 반환되는지 확인했다.
- EXP-007은 `detach(first)`와 `clear()`의 범위 차이를 `contains()`로 확인했다.
- EXP-008은 detached original을 `merge(original)`에 전달했을 때 original과 returned instance의 lifecycle과 object identity를 분리해 확인했다.
- EXP-009는 EXP-008의 identity 관찰 다음 단계로, detached original의 상태 변경값이 returned managed instance와 commit 후 row에 반영되는지 확인한다.

## 4. EXP-008과 다른 점

EXP-008은 detached original과 returned instance가 같은 Java object인지, 어느 instance가 managed 상태인지 확인했다. EXP-009는 object identity 결론을 유지한 상태에서 `merge()` 호출 직전 detached original의 `name`만 바꾸고, 그 변경값이 returned managed instance와 database row로 복사되는지 관찰한다.

## 5. 실험 범위

- 변경 파일은 focused test와 이 문서 두 파일뿐이다.
- production code, entity, Flyway/schema, application config, build/dependency, 기존 test source, 공용 fixture/helper, `ConsistencyVerifier`는 변경하지 않았다.
- production `BenchmarkRecord`와 production Flyway migration의 `benchmark_record` table을 그대로 사용한다.
- lifecycle 상태는 `EntityManager.contains()`로만 관찰한다.
- object identity는 `original == merged`로만 관찰한다.
- row/value identity는 ID와 저장 필드 값으로 구분한다.
- commit 후 정합성은 기존 `ConsistencyVerifier`로 확인한다.

## 6. 고정 조건

| 항목 | 값 |
|---|---|
| 실험 성격 | focused integration test |
| test class | `com.example.persistencebenchmark.JpaMergeDetachedStateCopyIntegrationTest` |
| entity | production `BenchmarkRecord` |
| table | production Flyway migration의 `benchmark_record` |
| entity ID strategy | production `GenerationType.IDENTITY` |
| input count | `1` |
| command source | `generatedCommands(1)` |
| `createdAt` | `2024-01-01T00:00:00Z` |
| updated `name` | `merge-detached-updated` |
| transaction boundary | test method가 아니라 `TransactionTemplate` |
| entity scan | `@EntityScan(basePackageClasses = BenchmarkRecord.class)` |
| official benchmark | `NOT_RUN` |
| profiler/JFR | `NOT_APPLIED` |

## 7. 변경 변수

변경 변수는 `clear()` 후 detached 상태가 된 original의 `name` 하나뿐이다. `businessKey`, `numericValue`, `occurredOn`, `createdAt`은 원래 command와 entity 생성 값을 유지한다.

`BenchmarkRecord`에는 production setter를 추가하지 않았다. test source 안에서 Spring Test의 `ReflectionTestUtils.setField(original, "name", UPDATED_NAME)`로 detached original의 `name`만 변경했다.

## 8. transaction 경계

test method에는 `@Transactional`을 붙이지 않는다. `TransactionTemplate.execute(...)` callback 안에서 command 생성, entity 생성, `persist()`, `flush()`, `clear()`, detached field change, `merge()` 관찰을 모두 수행한다. callback은 entity instance를 반환하지 않고 immutable command list와 boolean/scalar 값만 담은 observation record를 반환한다. callback 정상 반환으로 transaction commit이 끝난 뒤 `verifyExpected(expectedCommands)`로 database 정합성을 확인한다.

## 9. 관찰 순서

1. `generatedCommands(1)`에서 command 1건을 준비한다.
2. production factory `BenchmarkRecord.from(command, CREATED_AT)`로 original을 생성한다.
3. `entityManager.persist(original)`을 호출한다.
4. persist 직후 `entityManager.contains(original)`을 기록한다.
5. `entityManager.flush()`를 호출한다.
6. generated ID를 기록한다.
7. flush 직후 `entityManager.contains(original)`을 기록한다.
8. `entityManager.clear()`를 호출한다.
9. clear 직후 `entityManager.contains(original)`을 기록한다.
10. detached original의 `name`을 `merge-detached-updated`로 변경한다.
11. field 변경 후 original의 `name`을 기록한다.
12. `BenchmarkRecord merged = entityManager.merge(original)`을 호출한다.
13. merge 직후 original과 merged의 managed 상태를 기록한다.
14. merge 직후 `original == merged`를 기록한다.
15. original/merged ID와 저장 필드 값을 scalar로 기록한다.
16. processed count `1`을 기록한다.
17. callback을 정상 반환해 commit한다.
18. commit 후 변경된 `name`을 포함한 expected command list로 `verifyExpected(expectedCommands)`를 실행한다.

## 10. 실제 관찰값

Lifecycle boolean과 field value는 XML에 직접 출력된 값이 아니다. Evidence는 finalized test source의 직접 assertions와 focused XML 성공 결과의 결합으로 확인한다.

- persist 후 original managed: `true`
- flush 후 original managed: `true`
- clear 후 original managed: `false`
- merge 후 original managed: `false`
- merge 반환 instance managed: `true`
- original과 returned는 서로 다른 Java object: `true`
- original ID와 merged ID: non-null이며 equal
- field 변경 후 original `name`: `merge-detached-updated`
- merge 직후 returned instance `name`: `merge-detached-updated`
- unchanged stored fields: `businessKey`, `numericValue`, `occurredOn`, `createdAt`은 expected 값과 일치
- processed count: `1`

## 11. object identity와 row/value identity 구분

object identity는 `original == merged` 결과로만 판정한다. 이번 관찰에서 original과 returned instance는 같은 Java object가 아니다. row identity는 generated ID equality로 판정했고, 두 instance의 ID는 non-null이며 equal이었다. value identity는 저장 필드 값으로 판정했으며, 변경 변수인 `name`은 updated value로 같고 나머지 저장 필드는 expected 값과 같았다.

## 12. 정합성 결과

Commit 후 expected command는 원래 command의 `businessKey`, `numericValue`, `occurredOn`을 유지하고 `name`만 `merge-detached-updated`로 바꿔 구성했다.

- focused integration test: `VERIFIED`
- `ConsistencyReport.hasFailures()`: `false`
- row count: expected command count와 일치
- distinct business key count: row count와 일치
- missing business keys: empty
- unexpected business keys: empty
- duplicate business keys: empty
- normalized snapshot checksum: 변경된 expected command와 일치

## 13. runtime evidence identity

| 항목 | 값 |
|---|---|
| base HEAD | `d4609f96af6f81351bbb0eb1620f6bae960c89b0` |
| branch | `experiment/jpa-merge-detached-state-copy-observation` |
| finalized test source path | `src/test/java/com/example/persistencebenchmark/JpaMergeDetachedStateCopyIntegrationTest.java` |
| raw SHA-256 | `7e438f6c85081e5d0f67145c66c2e41c080033decec42fcc1e3d64961b18337d` |
| prospective Git blob ID | `11da0f747a4bb4c5ca9db8e694336e93b30d9f21` |
| line ending | LF-only |
| CRLF count | `0` |
| LF count | `150` |
| lone CR count | `0` |
| canonical blob byte SHA-256 | `7e438f6c85081e5d0f67145c66c2e41c080033decec42fcc1e3d64961b18337d` |
| raw/canonical relation | LF-only라 raw checkout byte SHA-256과 canonical blob byte SHA-256이 동일하다. |
| `core.autocrlf` | `true` |
| Git attributes | `text: auto`, `eol: unspecified`, `working-tree-encoding: unspecified` |
| exact focused command | `.\gradlew.bat --no-daemon test --rerun-tasks --tests "com.example.persistencebenchmark.JpaMergeDetachedStateCopyIntegrationTest"` |
| execution count | `1` |
| UTC start | `2026-08-19T15:00:52.3102006Z` |
| UTC end | `2026-08-19T15:01:17.9935106Z` |
| native exit code | `0` |
| XML path | `build/test-results/test/TEST-com.example.persistencebenchmark.JpaMergeDetachedStateCopyIntegrationTest.xml` |
| XML class | `com.example.persistencebenchmark.JpaMergeDetachedStateCopyIntegrationTest` |
| XML tests/failures/errors/skipped | `1` / `0` / `0` / `0` |
| XML timestamp | `2026-08-19T15:01:16.692Z` |
| XML last-write UTC | `2026-08-19T15:01:17.8175877Z` |
| XML timing relation | XML timestamp와 last-write가 recorded execution interval 안에 있다. |
| source hash after execution | `7e438f6c85081e5d0f67145c66c2e41c080033decec42fcc1e3d64961b18337d` |
| source hash unchanged | `true` |
| working-tree boundary | test와 doc는 stage/commit 전 untracked working-tree files다. |

## 14. evidence 해석

이번 evidence는 두 자료를 결합해 해석한다.

- finalized test source의 직접 assertions: lifecycle boolean, object identity, ID equality, field value copy, unchanged field equality, processed count, commit 후 consistency를 assertion한다.
- focused XML result: 지정 test class 1건이 failures/errors/skipped 없이 완료됐음을 보여준다.

XML이 lifecycle boolean이나 field value를 직접 출력한 것은 아니다.

## 15. 판정

현재 local runtime에서는 `clear()` 후 detached 상태인 original의 `name`을 바꾸고 `merge(original)`을 호출했을 때, original은 detached 상태로 남았고 returned instance만 managed 상태였다. original과 returned instance는 서로 다른 Java object였지만 같은 ID를 가졌고, `merge()` 호출 시점의 detached original `name` 값은 returned managed instance에 복사됐다. transaction commit 후 database row도 변경된 `name`을 기준으로 기존 consistency verifier를 통과했다.

Result code: `PERSISTENCE_LAB_MERGE_DETACHED_STATE_COPY_VERIFIED_LOCALLY`.

## 16. 해석 경계

이 결과는 현재 local runtime, production `BenchmarkRecord` 1건, production Flyway schema, Testcontainers PostgreSQL integration test 조건에 한정한다. public JPA API 관찰값과 commit 후 row consistency를 기록한 것이며, production 적용 권장이 아니다.

## 17. 한계와 제외 범위

- update SQL 횟수나 실행 시점을 판정하지 않는다.
- Hibernate 내부 구현 원인을 설명하지 않는다.
- dirty checking 전체 동작으로 일반화하지 않는다.
- detached original이 managed가 되었다고 설명하지 않는다.
- `merge()`가 original Java object를 persistence context에 재등록한다고 설명하지 않는다.
- concurrent update, optimistic locking, cascade `MERGE`, association lifecycle을 다루지 않는다.
- cache hit/miss, memory, persistence-context 크기, chunk 처리를 관찰하지 않는다.
- 성능 향상, benchmark, profiler, JFR 결과를 다루지 않는다.
- production code, entity, schema, config, dependency 변경을 다루지 않는다.
