---
name: persistence-experiment-lifecycle
description: "JPA/Hibernate persistence 동작을 focused integration test로 관찰하고 transaction, flush, clear, detach, merge, rollback 또는 chunk 경계의 Evidence를 문서화·검증·게시할 때 사용한다. 일반 production 기능 구현, 단순 unit test 또는 무관한 문서 수정에는 사용하지 않는다."
---

# Persistence Experiment Lifecycle

작은 persistence 질문 하나를 재현 가능한 test와 검증 가능한 문서 Evidence로 완결한다.

## 시작 절차

1. 현재 repository의 `AGENTS.md`, root, branch, worktree 상태와 현재 OS·shell을 확인한다.
2. 변경 전에 `$change-scope-triage`로 문제 실재성, 현재 범위, 최소 변경과 중단 조건을 판정한다.
3. 관찰 질문, 가설, 성공 Evidence와 non-goal을 각각 한 문장으로 고정한다.
4. 기존 integration-test convention, entity, constraint, transaction helper, cleanup 방식을 먼저 조사한다.

## 필요한 reference

- 실험을 설계하거나 test를 구현할 때는 [experiment-workflow.md](references/experiment-workflow.md)를 읽는다.
- validation을 실행하거나 문서 Evidence를 확정할 때는 [evidence-and-validation.md](references/evidence-and-validation.md)를 읽는다.

## 핵심 불변식

- production/API/schema/config/build 변경은 질문에 반드시 필요한 경우에만 별도 범위로 승인받는다.
- entity lifecycle, persistence-context 상태와 최종 database state를 서로 다른 Evidence로 다룬다.
- `flush()`, transaction 종료, commit, rollback 경계를 명시한다.
- callback 밖으로 mutable entity를 Evidence로 전달하지 않고 ID와 immutable scalar observation을 사용한다.
- cleanup은 captured ID allowlist를 사용해 별도 transaction에서 수행한다.
- failure 실험은 exception type뿐 아니라 failure phase와 필요한 SQLState·constraint identity를 검증한다.
- IDENTITY 전략이 의도한 explicit failure 지점보다 이른 INSERT를 만들 수 있는지 확인한다.

## 승인 경계

실험 구현과 validation, publication, merge, post-merge cleanup을 독립적인 승인 경계로 취급한다. 이미 검증한 source가 바뀌지 않은 문서 오탈자 correction만으로 runtime validation을 자동 재실행하지 않는다.

현재 OS와 shell에 맞는 Gradle wrapper 실행 방식을 선택한다. 이전 환경의 절대 경로나 운영체제 전용 명령을 현재 환경에 그대로 고정하지 않는다.
