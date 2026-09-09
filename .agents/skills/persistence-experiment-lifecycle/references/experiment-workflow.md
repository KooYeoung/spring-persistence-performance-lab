# Experiment Workflow

## 질문과 범위 고정

- 하나의 실험은 하나의 구체적인 persistence 질문에 답한다.
- 가설은 관찰 전에 작성하고 결과를 미리 단정하지 않는다.
- 성공 조건은 lifecycle, failure phase, database row와 field 등 직접 검증 가능한 Evidence로 정의한다.
- production source, public API, schema, config와 build 변경은 기본 non-goal이다. 꼭 필요하면 실험 test보다 먼저 별도 범위 승인을 받는다.
- 공용 runner, fixture, schema 또는 범용 harness가 핵심 실험보다 커지면 중단하고 범위를 재검토한다.

## 기존 convention 조사

Mutation 전에 관련 integration test, base test class, entity, migration, repository/service API와 가장 가까운 실험 문서를 읽는다. 기존 transaction helper, input 생성, assertion과 cleanup 방식을 우선 재사용한다.

새 production setter나 실험 전용 abstraction은 만들지 않는다. Test-only 상태 변경이 질문에 필수라면 기존 test convention과 Spring test utility처럼 제한된 수단을 사용하고 이유를 문서화한다.

## Lifecycle과 transaction 설계

각 관찰 지점에서 다음을 구분한다.

- Java object identity와 field value
- persistence context의 managed, detached 또는 removed 상태
- `persist()`, dirty checking, explicit `flush()`와 SQL failure phase
- transaction callback의 정상 반환 또는 exception 전파
- commit 또는 rollback 이후 별도 read transaction의 최종 database state

Transaction callback 밖에는 entity reference 대신 ID, key, value, phase와 같은 immutable scalar observation만 반환한다. 실패 transaction의 exception을 내부에서 삼켜 commit 가능 상태로 오인하지 않는다.

## Failure 유도 안전장치

- Failure가 질문의 어느 phase에서 발생해야 하는지 먼저 정한다.
- IDENTITY 생성 전략은 `persist()`에서 INSERT를 실행할 수 있다. Explicit `flush()` failure를 관찰하려면 처음에는 유효한 값을 persist한 뒤 managed state를 제한적으로 변경하는 방식이 더 정확할 수 있다.
- Exception type만으로 결론내리지 않는다. Cause chain에서 질문에 필요한 SQLState, constraint 또는 persistence exception identity를 검증한다.
- INSERT timing 자체가 질문이 아니라면 timing을 결론으로 일반화하지 않는다.

## Database 검증과 cleanup

- Commit 또는 rollback 뒤 별도 transaction에서 captured ID별 row count와 필요한 field를 확인한다.
- Expected ID allowlist와 실제 row set을 비교해 unexpected row를 확인한다.
- Cleanup은 `finally` 경계의 별도 transaction에서 수집된 ID만 중복 제거해 삭제한다.
- `deleteAll()`이나 넓은 business-key predicate를 기본 cleanup으로 사용하지 않는다.
- Cleanup 결과는 실험 assertion과 별도로 기록한다.

## Cross-platform 실행

현재 OS, shell, repository root와 Gradle wrapper 실행 권한을 확인한다. POSIX에서 wrapper가 executable이 아니면 `bash ./gradlew ...`처럼 현재 환경에서 동등한 방법을 사용하고, Windows에서는 repository가 지원하는 wrapper 형식을 사용한다. 한 운영체제의 절대 경로나 shell 문법을 보편 조건으로 만들지 않는다.

## 완료 경계

Focused test와 실험 문서는 하나의 질문을 설명해야 한다. README discovery, PR review 대응, merge와 source cleanup은 각각 독립 작업이 될 수 있으며 현재 승인 범위를 자동 확장하지 않는다.
