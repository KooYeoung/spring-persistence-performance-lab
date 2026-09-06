# EXP-010: JPA merge 이후 detached original 변경 관찰

상태: focused integration test `VERIFIED PASS`.

## 1. 실험 질문

`merge()` 호출 시점에 detached original의 `MERGE_TIME_NAME` 상태가 returned managed instance로 복사된 뒤, detached original만 `POST_MERGE_NAME`으로 다시 변경하면 managed copy와 실제 commit 이후 row는 `MERGE_TIME_NAME`을 유지하는가?

## 2. EXP-008/009와의 관계

- EXP-008은 detached original과 `merge()` returned instance가 서로 다른 Java object이며 original은 detached, returned instance는 managed 상태임을 관찰했다.
- EXP-009는 `merge()` 호출 전에 detached original의 값을 변경하면 그 값이 managed copy와 commit 이후 row에 복사됨을 관찰했다.
- EXP-010은 `merge()` 호출 이후 detached original만 다시 변경했을 때 그 후속 변경이 managed copy와 committed row에 전파되는지를 별도 질문으로 분리한다.

## 3. 실행 전 가설

- `merge()` 시점의 `MERGE_TIME_NAME`은 returned managed copy에 복사된다.
- `merge()` 이후 detached original만 `POST_MERGE_NAME`으로 변경해도 managed copy는 `MERGE_TIME_NAME`을 유지한다.
- Transaction B commit 이후 row의 `name`은 `MERGE_TIME_NAME`이며 `POST_MERGE_NAME`이 아니다.

이 항목들은 focused test가 통과하기 전까지 가설이며 결론은 `UNVERIFIED`다.

## 4. 고정 값

| 역할 | 값 |
|---|---|
| initial value A | `merge-post-call-initial` |
| merge 시점 value B | `merge-post-call-at-merge` |
| merge 이후 detached original value C | `merge-post-call-after-merge` |
| `createdAt` | `2024-01-01T00:00:00Z` |
| input count | `1` |

## 5. 환경과 source identity

| 항목 | 값 |
|---|---|
| base HEAD | `2a252c4e5315eba95501049f7be51229ed5bbf9e` |
| branch | `experiment/jpa-merge-detached-post-merge-mutation-observation` |
| Java toolchain | `21` |
| Spring Boot | `3.5.16` |
| database | Testcontainers PostgreSQL `postgres:17.6-alpine` |
| Docker server | `29.1.3` |
| test class | `com.example.persistencebenchmark.JpaMergeDetachedPostMergeMutationIntegrationTest` |
| test source canonical Git blob | `b05b31cbce33889690c82a6f1469460baabbeee7` |
| test source raw SHA-256 | `baeab07e4def3d2aab7fa29f839ed0e6d5873bfd31fbfd206d18f27350375b0c` |
| test source encoding/EOL | UTF-8 without BOM, LF-only |

## 6. 변경 범위

- 신규 focused integration test와 이 문서 두 파일만 추가한다.
- production source, entity, public API, Flyway/schema, application config, build/dependency, 기존 test helper와 README는 변경하지 않는다.
- production `BenchmarkRecord`, 기존 `TransactionTemplate`, `EntityManager`, `ReflectionTestUtils`와 `ConsistencyVerifier`를 그대로 사용한다.

## 7. transaction 절차

### Transaction A

1. deterministic command 한 건을 준비하고 `name`을 `INITIAL_NAME`으로 고정한다.
2. callback 밖에서 production factory로 original entity를 생성하고, callback 안에서 동일 instance에 `persist()`와 `flush()`를 실행한다.
3. generated ID, persist/flush 후 managed 상태와 initial value를 immutable scalar `PersistObservation`으로 반환한다.
4. callback 정상 반환으로 transaction을 실제 commit하고, callback 밖의 동일 original reference를 Transaction B의 detached input으로 유지한다.

### Transaction B

1. Transaction A 종료 후 detached original의 `name`을 `MERGE_TIME_NAME`으로 변경한다.
2. callback 진입 시 `EntityManager.contains(original)`이 `false`인지 확인한다.
3. `managedCopy = entityManager.merge(detachedOriginal)`을 정확히 한 번 호출한다.
4. original과 managedCopy가 다른 Java reference이며 ID가 같음을 확인한다.
5. original은 detached, managedCopy는 managed이고 양쪽 `name`이 `MERGE_TIME_NAME`인지 확인한다.
6. detached original만 `POST_MERGE_NAME`으로 변경한다.
7. original은 `POST_MERGE_NAME`, managedCopy는 계속 `MERGE_TIME_NAME`이며 lifecycle 상태가 유지되는지 확인한다.
8. immutable scalar `MergeObservation`을 반환하고 transaction을 실제 commit한다.

### Transaction C

1. 새로운 persistence context에서 같은 ID를 `find()`한다.
2. 조회 row가 managed이고 ID 및 전체 저장 필드가 expected 값과 일치하는지 확인한다.
3. committed `name`이 `MERGE_TIME_NAME`이고 `POST_MERGE_NAME`이 아닌지 확인한다.
4. `SELECT count(*) FROM benchmark_record WHERE id = ?`가 `1`인지 확인한다.
5. `MERGE_TIME_NAME`을 포함한 expected command로 기존 `verifyExpected`를 실행한다.

## 8. lifecycle, identity와 value assertions

- `assertNotSame(detachedOriginal, managedCopy)`
- original ID와 managedCopy ID는 non-null이며 동일
- Transaction B의 original `contains()`는 merge 전·후·C 변경 후 모두 `false`
- managedCopy `contains()`는 merge 후·C 변경 후 모두 `true`
- merge 시점의 original/managedCopy `name`은 `MERGE_TIME_NAME`
- C 변경 후 original `name`은 `POST_MERGE_NAME`, managedCopy `name`은 `MERGE_TIME_NAME`
- Transaction C row ID는 original ID와 동일
- committed row `name`은 `MERGE_TIME_NAME`이고 `POST_MERGE_NAME`이 아님
- 해당 ID row count는 `1`
- commit 후 normalized consistency report에 failure가 없음

## 9. cleanup

`finally`에서 generated ID가 있을 때만 별도 transaction으로 다음 SQL을 실행한다.

```sql
DELETE FROM benchmark_record WHERE id = ?
```

`deleteAll()`이나 다른 test data를 삭제하는 cleanup은 사용하지 않는다.

## 10. focused validation 명령

```powershell
.\gradlew.bat compileTestJava
.\gradlew.bat test --tests "com.example.persistencebenchmark.JpaMergeDetachedPostMergeMutationIntegrationTest"
```

Historical validation에서 compile exact command는 restricted sandbox와 승인된 escalated context에서 총 두 번 호출되었고, focused command는 한 번 호출되었다. 두 compile invocation은 별도 승인으로 사실 그대로 수용하며 compile과 focused test를 추가 실행하지 않는다.

## 11. validation 결과

| 항목 | 상태 |
|---|---|
| compile command | `.\gradlew.bat compileTestJava` |
| compile total historical invocation count | `2` |
| sandbox compile invocation / native exit | `1 / 1` |
| sandbox compile Gradle task | `NOT_REACHED` |
| sandbox failure boundary | local Gradle distribution lock 접근 거부, task 실행 전 종료 |
| escalated compile invocation / native exit | `1 / 0` |
| successful Gradle compile task execution | `1 / PASS` |
| focused command | `.\gradlew.bat test --tests "com.example.persistencebenchmark.JpaMergeDetachedPostMergeMutationIntegrationTest"` |
| focused total invocation / native exit | `1 / 0` |
| focused task result | `PASS` |
| application assertions | `VERIFIED PASS` |
| result | `PASS` |
| conclusion | `VERIFIED` |
| generated report | `GENERATED_NOT_INSPECTED` |
| generated XML/log direct access | `NOT_RUN` |

권한이 제한된 sandbox의 첫 Gradle wrapper invocation은 local Gradle distribution lock 접근 거부로 Gradle task 실행 전에 exit `1`이었다. 승인된 escalated context의 두 번째 invocation은 compile Gradle task를 한 번 실행해 exit `0`으로 완료했다. 첫 실패 Evidence를 성공 Evidence로 덮지 않으며, 두 historical compile invocation과 focused PASS 한 번을 별도 승인 범위로 수용한다.

## 12. 관찰 결과

- Transaction A는 callback 밖에서 생성한 original을 persist/flush하고 ID와 managed/value Evidence만 immutable `PersistObservation`으로 반환했다.
- Transaction B에서 detached original과 `merge()` returned managed copy는 서로 다른 Java reference이며 ID는 동일했다.
- original은 detached, returned copy는 managed 상태였다.
- merge 시점의 `MERGE_TIME_NAME`은 managed copy로 복사되었다.
- merge 이후 original만 `POST_MERGE_NAME`으로 변경해도 managed copy는 `MERGE_TIME_NAME`을 유지했다.
- 실제 commit 후 새 persistence context에서 조회한 row의 `name`은 `MERGE_TIME_NAME`이었고 `POST_MERGE_NAME`은 저장되지 않았다.
- 같은 ID의 row count는 `1`이었고 전체 저장 필드와 normalized consistency verification이 통과했다.
- cleanup은 generated ID가 존재할 때 해당 ID row 한 건만 별도 transaction으로 삭제했다.

## 13. 결론

현재 Testcontainers PostgreSQL 환경에서 `merge()` 이후 detached original만 변경한 값은 returned managed copy나 commit 이후 row로 전파되지 않았다. 이 결론은 이 실험의 scalar field와 transaction 경계 안에서만 `VERIFIED`다.

Result code:

`PERSISTENCE_LAB_MERGE_DETACHED_POST_MERGE_MUTATION_VERIFIED_LOCALLY`

## 14. 한계

- production `BenchmarkRecord` 한 건과 현재 Testcontainers PostgreSQL 환경에 한정한다.
- association, collection, cascade `MERGE`, SQL 횟수와 실행 시점, cache, concurrency, optimistic locking을 관찰하지 않는다.
- Hibernate 내부 구현이나 모든 JPA provider의 동작으로 일반화하지 않는다.
- 성능 benchmark, profiler, JFR 및 production 적용 권장을 다루지 않는다.

## 15. 후속 질문

- Association 또는 collection을 포함한 detached graph에서도 merge 이후 original 변경이 managed graph와 분리되는가?
- Optimistic locking version이 있는 entity에서 같은 순서를 관찰하면 commit 결과와 conflict 판정은 어떻게 달라지는가?

위 질문은 현재 EXP-010 범위 밖이며 별도 승인된 focused experiment로만 진행한다.
