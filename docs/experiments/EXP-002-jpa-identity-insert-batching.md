# EXP-002: JPA IDENTITY INSERT Batching 관찰

상태: focused integration test `VERIFIED`.

## 질문

`GenerationType.IDENTITY`를 사용하는 현재 JPA `saveAll` 경로에서 `hibernate.jdbc.batch_size=5`를 설정해도 Hibernate가 INSERT JDBC batch를 실행하지 않는가?

## 가설

Hibernate 6.6의 공식 계약에 따르면 JDBC batching은 `hibernate.jdbc.batch_size`로 활성화하지만, identity identifier generator를 사용하는 INSERT에는 batching이 투명하게 비활성화된다. 따라서 현재 entity가 `GenerationType.IDENTITY`를 사용하면 `saveAll` 입력 5건에 대해 저장과 정합성은 통과하더라도 save 구간의 Hibernate session metrics는 `0 JDBC batches`를 보고할 것으로 예상한다.

## 조건

| 항목 | 값 |
|---|---|
| 실험 성격 | focused integration test |
| DB | Testcontainers PostgreSQL `postgres:17.6-alpine` |
| 저장 경로 | `JpaBenchmarkRecordPersistenceService.saveAll` |
| entity ID strategy | `GenerationType.IDENTITY` |
| input count | `5` |
| configured Hibernate JDBC batch size | `5` |
| Hibernate statistics | `enabled` |
| SQL logging | `DEBUG` |
| JDBC batch logger | `org.hibernate.orm.jdbc.batch=TRACE` |
| resolved Hibernate ORM | `6.6.53.Final` |
| official benchmark | `NOT_RUN` |
| profiler/JFR | `NOT_APPLIED` |

## 실행 방법

Java test compilation:

```powershell
.\gradlew.bat --no-daemon compileTestJava
```

Focused integration test:

```powershell
.\gradlew.bat --no-daemon test --tests "com.example.persistencebenchmark.JpaIdentityInsertBatchingIntegrationTest"
```

전체 test suite, EXP-001 official benchmark, profiler/JFR, `rewriteBatchedInserts`, SEQUENCE 비교는 이 실험에 포함하지 않는다.

## 공식 Hibernate 계약

- Hibernate ORM 6.6 User Guide는 JDBC batching을 `hibernate.jdbc.batch_size` 설정으로 제어한다고 설명한다.
- 같은 문서는 Hibernate가 identity identifier generator를 사용하는 INSERT batching을 투명하게 비활성화한다고 설명한다.
- Hibernate ORM 6.6 Logging Guide는 `org.hibernate.orm.jdbc.batch`를 JDBC batch execution logger로 둔다.

참고 문서:

- <https://docs.hibernate.org/orm/6.6/userguide/html_single/>
- <https://docs.hibernate.org/orm/6.6/logging/logging.html>

## 실제 관찰값

실행:

- branch: `experiment/jpa-identity-batching-observation`
- production source revision: `1d881d6ddaf25eaca509b9ebdf4a6350878b77b2`
- execution tree state: EXP-002 test and document were present as untracked working tree files
- executed test file SHA-256: `e7bbfb8d0cc1419e75ae244b1504a84ab6795fbdd47e1da05eaeac94297e9465`
- first experiment commit: `6f9d417b58245b0c30ac6cea6358c3aa810e53fb`
- execution UTC: `2026-08-05T07:51:04Z`
- compile command: `.\gradlew.bat --no-daemon compileTestJava`
- compile native exit code: `0`
- focused test command: `.\gradlew.bat --no-daemon test --tests "com.example.persistencebenchmark.JpaIdentityInsertBatchingIntegrationTest"`
- focused test native exit code: `0`

Focused integration test 관찰값:

- effective Hibernate JDBC batch size: `5`
- Hibernate statistics enabled: `true`
- `savedCount`: `5`
- Hibernate `entityInsertCount`: `5`
- Hibernate `prepareStatementCount`: `> 0`
- save 구간 SQL log: `insert into benchmark_record ... values (?,?,?,?,?)` 5회
- save 구간 session metrics: `5 JDBC statements`
- save 구간 session metrics: `0 JDBC batches`
- `ConsistencyReport.hasFailures()`: `false`

`entityInsertCount`와 `prepareStatementCount`는 저장 실행 확인용 보조 지표이며, batch 미사용의 직접 증거로 해석하지 않는다.

## 정합성 결과

- focused integration test: `VERIFIED PASS`
- saved count: `VERIFIED`, `5`
- row count: `VERIFIED`, `5`
- distinct business key count: `VERIFIED`, `5`
- missing business keys: `VERIFIED`, empty
- unexpected business keys: `VERIFIED`, empty
- duplicate business keys: `VERIFIED`, empty
- checksum equality: `VERIFIED`

## 판정 수준

현재 판정: `VERIFIED_LOCAL`.

Local runtime save 구간에서 `0 JDBC batches`가 직접 관찰되었고 정합성이 통과했다.

Result code: `PERSISTENCE_LAB_IDENTITY_BATCHING_VERIFIED_LOCALLY`.

## 한계

- 입력 5건의 동작 관찰 실험이며 50,000건 성능 비교가 아니다.
- Testcontainers 기반 integration test 결과이며 EXP-001 official benchmark target 결과가 아니다.
- `SEQUENCE`, pooled optimizer, `rewriteBatchedInserts`, JDBC driver rewrite 동작은 비교하지 않는다.
- `entityInsertCount`와 `prepareStatementCount`만으로 batch 여부를 결론내리지 않는다.
- Hibernate session metrics 형식이 바뀌어 batch count를 파싱하지 못하면 evidence 부족으로 실패 처리하고 자동 재시도하지 않는다.

## 다음 질문

IDENTITY가 아닌 ID 전략을 명시적으로 승인한 별도 실험에서 같은 저장 경로가 JDBC batch를 실행하는지 비교할 필요가 있는가?
