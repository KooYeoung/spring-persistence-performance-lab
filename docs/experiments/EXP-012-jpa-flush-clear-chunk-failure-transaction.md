# EXP-012: JPA chunk 실패 transaction 경계 관찰

상태: focused integration test `VERIFIED PASS`.

## 1. 실험 질문

두 번째 chunk의 명시적 `flush()`에서 unique constraint violation이 발생할 때, 두 chunk를 하나의 transaction으로 처리하면 전체가 rollback되고 chunk별 transaction으로 처리하면 첫 chunk commit만 보존되는가?

## 2. EXP-011과의 관계

- EXP-011은 하나의 transaction에서 A/B와 C/D를 두 chunk로 정상 처리했을 때 `flush()`와 `clear()`의 lifecycle 경계 및 네 row의 최종 commit을 관찰했다.
- EXP-011은 chunk 실패와 부분 commit을 범위 밖으로 두고, 하나의 transaction rollback과 별도 transaction 전략의 차이를 후속 질문으로 남겼다.
- EXP-012는 entity 수와 chunk 크기를 유지하고 두 번째 chunk의 실패 및 transaction 경계만 새 변수로 둔다.

## 3. 실행 전 가설

- Scenario A에서 두 번째 chunk가 실패하면 같은 transaction의 A/B/C/D가 모두 rollback된다.
- Scenario B에서 첫 transaction의 A/B는 commit되고, 두 번째 transaction의 C/D만 rollback된다.
- 두 scenario 모두 unique constraint violation은 정상 key를 가진 C/D를 persist한 뒤 managed C의 `businessKey`를 A와 같게 변경하고 명시적으로 `flush()`할 때 관찰된다.

Focused test가 통과하기 전까지 위 내용은 hypothesis이며 runtime evidence와 conclusion은 `UNVERIFIED`다.

## 4. 고정 조건

| 항목 | 값 |
|---|---|
| scenarios | single transaction, transaction per chunk |
| chunk count / size | `2 / 2` |
| entities per scenario | A, B, C, D |
| failure entity | managed C |
| conflicting value | C `businessKey` → A `businessKey` |
| failure phase | second-chunk explicit `flush()` |
| expected SQLState | PostgreSQL unique violation `23505` |
| expected constraint | `uk_benchmark_record_business_key` |
| `createdAt` | `2024-01-01T00:00:00Z` |
| input namespace | fixed prefix + UUID suffix |

## 5. 환경과 source identity

| 항목 | 값 |
|---|---|
| base HEAD | `bf436599830ba8f64dbdfe68ea6580cdc04c8cdf` |
| branch | `experiment/jpa-flush-clear-chunk-failure-transaction-boundary` |
| Java toolchain | `21` |
| Spring Boot | `3.5.16` |
| database | Testcontainers PostgreSQL `postgres:17.6-alpine` |
| Docker server | `29.5.2` |
| test class | `com.example.persistencebenchmark.JpaFlushClearChunkFailureTransactionIntegrationTest` |
| test source canonical Git blob | `0dce9b43dd3f2aa0889f04ca51b01c1da8060a7e` |
| test source raw SHA-256 | `740d03bfe4c251f42edc1e35ad9b4529523a561db8c4b4878dc7ad2a102680e0` |
| test source encoding/EOL | UTF-8 without BOM, LF-only |

## 6. 변경 범위

- 신규 focused integration test와 이 문서 두 파일만 추가한다.
- production source, entity, public API, Flyway/schema, application config, build/dependency, 기존 helper와 README는 변경하지 않는다.
- 기존 `TransactionTemplate`, `EntityManager`, `BenchmarkRecord`, `ReflectionTestUtils`, `verifyExpected`와 unique constraint를 그대로 사용한다.

## 7. transaction 절차

### Scenario A: single transaction

1. A/B를 서로 다른 정상 business key로 persist하고 `flush()`한 뒤 ID와 managed 상태를 scalar로 확보한다.
2. `clear()` 뒤 A/B가 detached인지 scalar snapshot으로 확인한다.
3. C/D를 서로 다른 정상 business key로 persist하고 managed 상태 및 ID를 확보한다.
4. managed C의 `businessKey`를 reflection으로 A의 key와 같게 변경한다.
5. transaction callback 밖의 `assertThrows`가 명시적 `flush()`의 exception을 관찰하도록 예외를 전파한다.
6. rollback 완료 뒤 별도 read transaction에서 A/B/C/D ID row가 모두 없는지 확인하고 `verifyExpected(List.of())`를 실행한다.

### Scenario B: transaction per chunk

1. 첫 transaction에서 A/B를 persist하고 `flush()`한 뒤 ID와 managed 상태를 확보한다.
2. `clear()`로 A/B가 detached가 된 것을 확인하고 callback 정상 반환으로 첫 transaction을 commit한다.
3. 두 번째 transaction에서 C/D를 정상 business key로 persist한 뒤 managed C의 key를 A와 같게 변경한다.
4. transaction callback 밖의 `assertThrows`가 명시적 `flush()`의 exception을 관찰하도록 예외를 전파하고 두 번째 transaction만 rollback한다.
5. 별도 read transaction에서 A/B의 전체 저장 필드와 C/D ID row 부재를 확인한다.
6. `verifyExpected(A/B commands)`로 row count `2`, key/checksum 및 unexpected row 부재를 검증한다.

## 8. lifecycle, failure와 rollback assertions

| 관찰 | Scenario A | Scenario B |
|---|---|---|
| Chunk 1 persist/flush | A/B managed | A/B managed |
| Chunk 1 clear | A/B detached | A/B detached 뒤 commit |
| Chunk 2 persist | C/D managed | C/D managed |
| 실패 주입 | managed C dirty update | managed C dirty update |
| failure phase | explicit second-chunk `flush()` | explicit second-chunk `flush()` |
| cause identity | SQLState `23505`, expected constraint | SQLState `23505`, expected constraint |
| rollback 이후 | A/B/C/D row `0` | A/B row `2`, C/D row `0` |

각 scenario의 네 generated ID는 non-null이고 중복이 없어야 하며, transaction 밖에는 entity reference가 아니라 immutable scalar observation만 보존한다.

## 9. IDENTITY failure-timing 안전장치

`BenchmarkRecord`는 `GenerationType.IDENTITY`를 사용하므로 처음부터 duplicate business key를 가진 entity를 `persist()`하면 INSERT와 failure가 명시적 `flush()`보다 먼저 발생할 수 있다. 따라서 C/D는 정상 key로 persist하고 managed C의 field를 reflection으로 변경한 직후 `flush()`한다. 결론은 rollback 범위에만 한정하며 INSERT 시점이나 ID 연속성을 일반화하지 않는다.

## 10. cleanup

`finally`에서 두 scenario가 확보한 ID를 중복 제거하고 별도 transaction에서 각 ID에 다음 SQL만 실행한다.

```sql
DELETE FROM benchmark_record WHERE id = ?
```

Rollback된 ID의 delete count `0`은 정상이다. `deleteAll()`, business-key cleanup 또는 table-wide cleanup은 사용하지 않으며 cleanup 뒤 captured ID의 remaining row count가 `0`인지 확인한다.

## 11. focused validation 명령

```bash
bash ./gradlew compileTestJava
bash ./gradlew test --tests "com.example.persistencebenchmark.JpaFlushClearChunkFailureTransactionIntegrationTest"
```

각 명령은 최대 한 번만 실행한다. Compile 실패 시 focused test는 `NOT_REACHED`이며 source/document correction이나 자동 재실행을 수행하지 않는다.

## 12. validation 결과

| 항목 | 상태 |
|---|---|
| compile command | `bash ./gradlew compileTestJava` |
| compile invocation / native exit | `1 / 0` |
| compile Gradle task | `compileTestJava` `PASS` |
| focused command | `bash ./gradlew test --tests "com.example.persistencebenchmark.JpaFlushClearChunkFailureTransactionIntegrationTest"` |
| focused invocation / native exit | `1 / 0` |
| focused Gradle task | `test` `PASS` |
| Docker/Testcontainers | PostgreSQL `postgres:17.6-alpine` 사용 |
| application assertions | `VERIFIED PASS` |
| runtime result | `PASS` |
| conclusion | `VERIFIED` |
| generated report | `GENERATED_NOT_INSPECTED` |
| generated XML/log direct access | `NOT_RUN` |

## 13. 관찰 결과

- 두 scenario 모두 cause chain에 Hibernate `ConstraintViolationException`이 있었고 SQLState는 `23505`, constraint는 `uk_benchmark_record_business_key`였다.
- 두 scenario 모두 정상 key로 C/D를 persist한 뒤 managed C의 key를 A와 같게 변경했으며 exception은 두 번째 chunk의 명시적 `flush()` phase에서 관찰됐다.
- Scenario A의 rollback 이후 A/B/C/D 네 captured ID의 row count는 각각 `0`이었고 `verifyExpected(List.of())`의 row count도 `0`이었다.
- Scenario B의 첫 transaction에서 A/B가 commit됐고 별도 read transaction에서 두 row의 ID, business key, name, numeric value, occurred date와 created timestamp가 expected 값과 일치했다.
- Scenario B의 실패한 두 번째 transaction 이후 C/D row count는 각각 `0`이었고 `verifyExpected(A/B commands)`의 row count는 `2`였으며 unexpected row는 없었다.
- Cleanup은 두 scenario에서 확보한 ID `8`개에만 수행됐고 committed A/B row `2`개를 삭제한 뒤 captured ID의 remaining row count는 `0`이었다.
- Test source canonical Git blob `0dce9b43dd3f2aa0889f04ca51b01c1da8060a7e`와 raw SHA-256 `740d03bfe4c251f42edc1e35ad9b4529523a561db8c4b4878dc7ad2a102680e0`은 validation 전후 동일했다.

## 14. 결론

현재 Testcontainers PostgreSQL 환경에서 두 번째 chunk의 unique constraint violation을 하나의 transaction 안에서 발생시키면 첫 chunk를 포함한 A/B/C/D 전체가 rollback됐다. Chunk별 transaction에서는 먼저 commit된 A/B 두 row가 유지되고 실패한 두 번째 transaction의 C/D만 rollback됐다.

이 결론은 현재 `BenchmarkRecord`, PostgreSQL unique constraint와 명시적 `flush()`에서 관찰한 transaction rollback 범위에만 한정한다. `GenerationType.IDENTITY`의 INSERT 시점이나 ID 연속성에 대한 결론으로 일반화하지 않는다.

Result code:

`PERSISTENCE_LAB_CHUNK_FAILURE_TRANSACTION_BOUNDARY_VERIFIED_LOCALLY`

## 15. 한계와 후속 질문

- 현재 production `BenchmarkRecord`, PostgreSQL unique constraint와 단일 thread Testcontainers 환경에 한정한다.
- IDENTITY sequence gap, INSERT/UPDATE SQL 횟수와 실행 시점, batching, 성능, memory를 결론으로 다루지 않는다.
- 다른 constraint, exception translation, retry, concurrency, optimistic locking과 production batch orchestration을 관찰하지 않는다.
- transaction propagation 변경이나 chunk orchestration 구현 권장으로 일반화하지 않는다.
- 후속으로 다른 constraint 또는 concurrent transaction에서도 rollback 경계가 같은지 관찰할 수 있지만 별도 승인이 필요하다.
