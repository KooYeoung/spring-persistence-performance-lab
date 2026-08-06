# EXP-006: JPA clear 후 find instance identity 관찰

상태: focused integration test `VERIFIED`.

## 질문

`EntityManager.clear()`로 기존 entity instance가 detached 된 뒤 같은 ID를 `find()`하면, 기존 instance가 다시 managed 상태가 되는가 아니면 같은 row를 나타내는 다른 managed instance가 반환되는가?

## 가설

`clear()`는 persistence context의 managed entity tracking을 비운다. 따라서 `clear()` 후 기존 instance는 detached 상태로 남고, 같은 ID로 `find()`하면 같은 database row를 나타내는 새 managed instance가 반환될 것으로 예상한다.

## EXP-005와의 연결

- EXP-005는 같은 transaction과 같은 entity instance에서 `persist()` 직후와 `flush()` 직후 `contains(entity)`가 `true`, `clear()` 직후 `false`가 되는 것을 확인했다.
- EXP-006은 `clear()` 이후 같은 ID를 다시 조회했을 때 object identity와 row identity가 어떻게 분리되는지 확인한다.
- 이 실험은 SQL 실행 시점, persistence context 내부 크기, memory 감소, chunk 성능, JDBC batch 효과를 판정하지 않는다.

## 실행 조건

| 항목 | 값 |
|---|---|
| 실험 성격 | focused integration test |
| DB | Testcontainers PostgreSQL `postgres:17.6-alpine` |
| test class | `com.example.persistencebenchmark.JpaClearFindInstanceIdentityIntegrationTest` |
| entity | production `BenchmarkRecord` |
| table | production Flyway migration의 `benchmark_record` |
| entity ID strategy | production `GenerationType.IDENTITY` |
| input count | `1` |
| transaction boundary | test method가 아니라 `TransactionTemplate` |
| direct lifecycle metric | `EntityManager.contains(entity)` |
| object identity metric | `original == reloaded` |
| row identity metric | generated ID와 entity 저장 필드 동일성 |
| official benchmark | `NOT_RUN` |
| profiler/JFR | `NOT_APPLIED` |

## Transaction 경계

- test method에는 `@Transactional`을 붙이지 않는다.
- `TransactionTemplate` 안에서 deterministic command 1건으로 `BenchmarkRecord` entity를 만든다.
- 같은 transaction과 같은 `EntityManager`에서 `persist()`, `flush()`, `clear()`, `find()`를 순서대로 호출한다.
- transaction 반환 후 lifecycle 관찰값을 assertion한다.
- transaction commit 후 기존 `ConsistencyVerifier`로 저장 결과 정합성을 확인한다.

## 관찰 순서

1. `BenchmarkRecord.from(command, fixedCreatedAt)`으로 original entity를 생성한다.
2. `entityManager.persist(original)`을 호출한다.
3. `persist()` 직후 original instance의 `contains(original)` 값을 기록한다.
4. `entityManager.flush()` 후 original ID와 `contains(original)` 값을 기록한다.
5. `entityManager.clear()` 후 `contains(original)` 값을 기록한다.
6. 같은 ID로 `entityManager.find(BenchmarkRecord.class, id)`를 호출한다.
7. `find()` 후 original instance의 `contains()` 값과 reloaded instance의 `contains()` 값을 기록한다.
8. original과 reloaded가 같은 object instance인지 기록한다.
9. original과 reloaded의 ID 및 entity 저장 필드가 같은지 기록한다.
10. transaction commit 후 저장된 row의 정합성을 검증한다.

## 예상 관찰값

- original after `persist()`: managed
- original after `flush()`: managed
- original after `clear()`: detached
- original after `find()`: detached
- reloaded after `find()`: managed
- object identity: original과 reloaded는 다른 instance
- row identity: original과 reloaded의 ID 및 entity 저장 필드는 동일

## 실제 관찰값

### Initial focused test

Initial focused test는 PASS였지만, commit 전 read-only audit에서 `persist()` 직후 original instance의 managed 상태 assertion이 누락된 것을 required finding으로 확인했다. 이 initial PASS는 final corrected source의 PASS로 재해석하지 않는다.

- branch: `experiment/jpa-clear-find-instance-identity-observation`
- source revision: `f0b2e4e32ca9da3acc2c62e5ce0a5429a5b6d4c5`
- execution tree state: EXP-006 test와 문서가 uncommitted working tree files로 존재
- executed test source SHA-256: `9C28AD9111C5721CBB0CFFEC5276A13BBCA2CF06C4BEC22383C46D01FAB28852`
- test source Git object ID from current working-tree bytes: `497baa38c3abedab21c790792f155042582e064e`
- focused test command: `.\gradlew.bat --no-daemon test --tests "com.example.persistencebenchmark.JpaClearFindInstanceIdentityIntegrationTest"`
- focused test native exit code: `0`
- XML timestamp: `2026-08-06T16:25:44.024Z`
- XML result: tests `1`, failures `0`, errors `0`, skipped `0`

### Required finding correction rerun

실행:

- branch: `experiment/jpa-clear-find-instance-identity-observation`
- base HEAD: `f0b2e4e32ca9da3acc2c62e5ce0a5429a5b6d4c5`
- execution tree state: EXP-006 test와 문서가 untracked working tree files로 존재
- finalized test source: `src/test/java/com/example/persistencebenchmark/JpaClearFindInstanceIdentityIntegrationTest.java`
- finalized test source SHA-256 before execution: `FCB45A75058D6350F07E19880EAB2B31590B47A9E4F55AA64D3700C7AD315AC3`
- finalized test source SHA-256 after execution: `FCB45A75058D6350F07E19880EAB2B31590B47A9E4F55AA64D3700C7AD315AC3`
- test source Git object ID from current working-tree bytes: `7a91d7e748b50638712a3ab1b9610d20ff4494c9`
- command: `.\gradlew.bat --no-daemon test --rerun-tasks --tests "com.example.persistencebenchmark.JpaClearFindInstanceIdentityIntegrationTest"`
- started at UTC: `2026-08-06T16:39:54.2082469Z`
- ended at UTC: `2026-08-06T16:40:21.8237305Z`
- native exit code: `0`
- Gradle `:test` task: executed
- Gradle result: `BUILD SUCCESSFUL`
- XML timestamp: `2026-08-06T16:40:16.042Z`
- XML result: tests `1`, failures `0`, errors `0`, skipped `0`

Focused integration test 관찰값:

- original after `persist()`: managed
- original after `flush()`: managed
- original after `clear()`: detached
- original after `find()`: detached
- reloaded after `find()`: managed
- object identity: original과 reloaded는 다른 instance
- row identity: original과 reloaded의 ID 및 entity 저장 필드는 동일
- processed command count: `1`

## 정합성 기준

- focused integration test가 통과해야 한다.
- `ConsistencyReport.hasFailures()`가 `false`여야 한다.
- row count, distinct business key count, normalized snapshot checksum이 입력 1건과 일치해야 한다.

## 정합성 결과

- focused integration test: `VERIFIED PASS`
- `ConsistencyReport.hasFailures()`: `false`
- row count: `VERIFIED`, expected command count와 일치
- distinct business key count: `VERIFIED`, expected business key count와 일치
- normalized snapshot checksum: `VERIFIED`, 입력 1건과 일치

## 판정 기준

가설이 지지되려면 다음이 모두 확인되어야 한다.

- `persist()` 직후 original `contains()`가 `true`
- `flush()` 후 original `contains()`가 `true`
- `clear()` 후 original `contains()`가 `false`
- `find()` 후 original `contains()`가 계속 `false`
- `find()`로 반환된 reloaded instance의 `contains()`가 `true`
- original과 reloaded가 같은 object instance가 아님
- original과 reloaded의 ID 및 entity 저장 필드가 같음
- commit 후 정합성 검증 통과

## 판정

현재 판정: `VERIFIED_LOCAL`.

같은 transaction에서 `persist()` 직후 original instance는 managed 상태였고, `clear()` 후에는 detached 상태로 남았다. 같은 ID로 `find()`한 reloaded instance는 managed 상태였다. 두 instance는 같은 object가 아니지만 같은 generated ID와 entity 저장 필드를 가진 같은 database row를 나타냈다. transaction commit 후 저장 정합성도 통과했다.

Result code: `PERSISTENCE_LAB_CLEAR_FIND_INSTANCE_IDENTITY_VERIFIED_LOCALLY`.

## 한계

- `find()`가 SQL을 실행했는지 판정하지 않는다.
- object identity와 database row identity를 같은 의미로 취급하지 않는다.
- transaction commit 효과와 `detach()` 동작을 비교하지 않는다.
- persistence context 내부 collection 크기나 memory 사용량을 측정하지 않는다.
- chunk 단위 `flush()/clear()`나 대량 저장 성능 개선을 검증하지 않는다.
- production service에 `clear()` 또는 `find()`를 추가해야 한다는 결론이 아니다.
- production entity, production Flyway migration, application 기본 설정은 변경하지 않는다.

## 실행 방법

Focused integration test:

```powershell
.\gradlew.bat --no-daemon test --rerun-tasks --tests "com.example.persistencebenchmark.JpaClearFindInstanceIdentityIntegrationTest"
```

전체 test suite, EXP-001 official benchmark, profiler/JFR, SQL log 분석, production service 변경은 포함하지 않는다.

## 다음 질문

`clear()` 후 같은 row를 새 managed instance로 다시 조회하는 것이 확인되면, 여러 entity를 일정 단위로 저장할 때 `flush()/clear()`가 chunk 경계의 managed 상태를 어떻게 바꾸는지는 별도 실험으로 분리할 필요가 있는가?
