# EXP-011: JPA flush/clear chunk 경계 상태 관찰

상태: focused integration test `VERIFIED PASS`.

## 1. 실험 질문

하나의 transaction에서 entity 네 건을 두 개의 논리적 chunk로 저장할 때, `flush()`는 현재 persistence context의 managed 상태를 유지하고 `clear()`는 context 전체 entity를 detached 상태로 전환하며, 다음 chunk entity는 새로 managed 상태가 되고 두 chunk 모두 최종 commit되는가?

## 2. EXP-005/006과의 관계

- EXP-005는 단일 entity에서 `persist()`와 `flush()` 뒤 managed 상태가 유지되고 `clear()` 뒤 detached가 되는지 관찰했다.
- EXP-006은 `clear()` 뒤 기존 instance가 detached로 남고 같은 row를 `find()`하면 다른 managed instance가 반환되는지 관찰했다.
- EXP-011은 같은 lifecycle 질문을 하나의 transaction 안의 두 논리적 chunk와 네 entity로 확장한다.

## 3. 실행 전 가설

- Chunk 1의 A/B는 첫 `flush()` 뒤에도 managed 상태다.
- 첫 `clear()`는 A/B를 detached로 전환한다.
- Chunk 2의 C/D를 persist하면 A/B는 detached로 남고 C/D만 managed 상태다.
- 두 번째 `clear()` 뒤 A/B/C/D 모두 detached 상태다.
- write transaction commit 뒤 네 row와 expected 저장 필드는 모두 유지된다.

Focused test가 통과하기 전까지 위 내용은 hypothesis이며 result와 conclusion은 `UNVERIFIED`다.

## 4. 고정 조건

| 항목 | 값 |
|---|---|
| chunk count | `2` |
| chunk size | `2` |
| entities | A, B, C, D |
| write transaction | `1` |
| read transaction | `1` |
| `createdAt` | `2024-01-01T00:00:00Z` |

## 5. 환경과 source identity

| 항목 | 값 |
|---|---|
| base HEAD | `2a252c4e5315eba95501049f7be51229ed5bbf9e` |
| branch | `experiment/jpa-flush-clear-chunk-boundary-observation` |
| Java toolchain | `21` |
| Spring Boot | `3.5.16` |
| database | Testcontainers PostgreSQL `postgres:17.6-alpine` |
| Docker server | `29.1.3` |
| test class | `com.example.persistencebenchmark.JpaFlushClearChunkBoundaryIntegrationTest` |
| test source canonical Git blob | `b7dcf25600ee42c788af9eff09bfeae35f1a81c5` |
| test source raw SHA-256 | `a29e221935c9950c1d9c8048f6ba4188a8a7109236311c6417ab311bc9a84742` |
| test source encoding/EOL | UTF-8 without BOM, LF-only |

## 6. 변경 범위

- 신규 focused integration test와 이 문서 두 파일만 추가한다.
- production source, entity, public API, Flyway/schema, application config, build/dependency, 기존 helper와 README는 변경하지 않는다.

## 7. transaction 절차

### Write transaction

1. A/B를 persist하고 두 instance가 managed인지 확인한다.
2. 첫 `flush()` 뒤 A/B가 계속 managed이고 generated ID가 존재하는지 확인한다.
3. 첫 `clear()` 뒤 A/B가 detached인지 확인한다.
4. C/D를 persist하고 A/B는 detached, C/D는 managed인지 확인한다.
5. 두 번째 `flush()` 뒤에도 A/B는 detached, C/D는 managed이고 C/D ID가 존재하는지 확인한다.
6. 두 번째 `clear()` 뒤 A/B/C/D 모두 detached인지 확인한다.
7. entity reference 대신 lifecycle 값과 네 ID를 immutable scalar observation으로 반환하고 transaction을 commit한다.

### Read transaction

1. 새 persistence context에서 네 ID를 각각 조회한다.
2. 조회 instance가 managed이고 ID와 전체 저장 필드가 expected command와 일치하는지 확인한다.
3. transaction 밖에는 immutable row snapshot만 반환한다.

Commit 이후 기존 `verifyExpected(commands)`로 row count `4`, key/checksum과 normalized 저장 정합성을 검증한다.

## 8. lifecycle assertions

| 경계 | A/B | C/D |
|---|---|---|
| Chunk 1 persist 후 | managed | transient |
| 첫 flush 후 | managed | transient |
| 첫 clear 후 | detached | transient |
| Chunk 2 persist 후 | detached | managed |
| 두 번째 flush 후 | detached | managed |
| 두 번째 clear 후 | detached | detached |

네 generated ID는 non-null이고 모두 distinct여야 한다.

## 9. cleanup

`finally`에서 확보된 ID가 있을 때만 별도 transaction으로 각 ID row에 다음 SQL을 실행한다.

```sql
DELETE FROM benchmark_record WHERE id = ?
```

`deleteAll()`이나 다른 test data를 삭제하는 cleanup은 사용하지 않는다.

## 10. focused validation 명령

```powershell
.\gradlew.bat compileTestJava
.\gradlew.bat test --tests "com.example.persistencebenchmark.JpaFlushClearChunkBoundaryIntegrationTest"
```

각 명령은 최대 한 번만 실행한다. Compile 실패 시 focused test는 실행하지 않고, 실패 후 source/document correction이나 재실행을 수행하지 않는다.

## 11. validation 결과

| 항목 | 상태 |
|---|---|
| compile command | `.\gradlew.bat compileTestJava` |
| compile invocation / native exit | `1 / 0` |
| focused command | `.\gradlew.bat test --tests "com.example.persistencebenchmark.JpaFlushClearChunkBoundaryIntegrationTest"` |
| focused invocation / native exit | `1 / 0` |
| application assertions | `VERIFIED PASS` |
| result | `PASS` |
| conclusion | `VERIFIED` |
| generated report | `GENERATED_NOT_INSPECTED` |
| generated XML/log direct access | `NOT_RUN` |

## 12. 관찰 결과

- 첫 `flush()` 뒤 A/B는 모두 managed 상태였다.
- 첫 `clear()` 뒤 A/B는 모두 detached 상태였다.
- C/D를 persist하고 두 번째 `flush()`한 뒤 A/B는 detached 상태를 유지했고 C/D는 managed 상태였다.
- 두 번째 `clear()` 뒤 A/B/C/D 네 entity는 모두 detached 상태였다.
- 네 generated ID는 non-null이고 모두 distinct였다.
- 별도 read transaction에서 네 row가 managed 상태로 조회됐고 ID와 전체 저장 필드가 expected command와 일치했다.
- `verifyExpected(commands)`의 row count `4`, key/checksum과 normalized consistency 검증이 통과했다.
- cleanup은 확보된 네 ID에 한정해 별도 transaction으로 수행했다.
- Test source raw SHA-256은 validation 전후 `a29e221935c9950c1d9c8048f6ba4188a8a7109236311c6417ab311bc9a84742`로 동일했다.

## 13. 결론

현재 Testcontainers PostgreSQL 환경에서 `flush()`는 현재 chunk entity의 managed 상태를 유지했고, `clear()`는 persistence context 전체 entity를 detached 상태로 전환했다. 다음 chunk entity는 새로 managed 상태가 되었으며 두 chunk의 네 row는 write transaction commit 후 모두 확인되었다.

`GenerationType.IDENTITY`에서는 `persist()` 시 INSERT가 발생할 수 있으므로 이 결과를 SQL 실행 시점에 대한 결론으로 일반화하지 않는다.

Result code:

`PERSISTENCE_LAB_FLUSH_CLEAR_CHUNK_BOUNDARY_VERIFIED_LOCALLY`

## 14. 한계

- `clear()`는 논리적 chunk만 선택적으로 비우는 것이 아니라 현재 persistence context 전체를 비운다.
- 현재 entity는 `GenerationType.IDENTITY`를 사용하므로 `persist()` 시 INSERT가 발생할 수 있다. 이 실험으로 SQL 실행 시점을 일반화하지 않는다.
- SQL 횟수, JDBC batching, batch size, 성능, memory, detached entity 추가 변경, `merge()`, chunk 실패나 부분 commit, bulk insert와 production batch orchestration은 관찰 범위 밖이다.
- 현재 Testcontainers PostgreSQL과 단일 thread 실행을 다른 JPA provider 또는 운영 환경 전체로 일반화하지 않는다.

## 15. 후속 질문

- 더 큰 chunk에서도 각 `clear()` 뒤 persistence context lifecycle 경계가 같은가?
- 실패가 포함된 chunk 처리에서는 하나의 transaction rollback과 별도 transaction 전략이 어떤 차이를 보이는가?

위 질문은 EXP-011 범위 밖이며 별도 승인된 실험으로만 진행한다.
