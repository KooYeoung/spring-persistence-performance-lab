---
name: change-scope-triage
description: 코드, 문서, 실험, 지원 도구 변경 전 read-only로 문제 실재 여부, 현재 범위 필요성, 최소 변경, 과설계, 중단 또는 보류 여부와 PR review finding 분류를 판단할 때 사용합니다.
---

## Purpose

mutation 전에 현재 요청이 실제로 필요한 변경인지 read-only로 판정한다.

이 Skill은 파일, Git, GitHub, Issue, PR 상태를 직접 수정하지 않는다. 출력은 최소 변경 진행, 변경 없음, 후속 분리, 현재 작업 중단 중 하나를 선택하기 위한 근거다.

## Use This Skill When

- 코드, 문서, 실험 결과, 스크립트, fixture, validator를 변경하기 전에 문제 실재 여부를 확인해야 한다.
- PR review comment, unresolved thread, CI 실패, 문서 불일치가 현재 Issue 범위에서 반드시 고쳐야 하는지 판단해야 한다.
- 제안된 수정이 Source of Truth, 완료 조건, Evidence 원칙과 충돌하는지 확인해야 한다.
- 지원 도구 확장, 재시도, 후속 Issue, 새 실험, 새 문서 생성이 과설계 또는 review limit 우회인지 판단해야 한다.
- 현재 작업을 계속할지, 보류할지, 사람 검토로 넘길지 결정해야 한다.

## Required Context

- 현재 사용자 요청, Issue 목적, 완료 조건, Non-goal.
- `AGENTS.md`와 저장소의 Source of Truth 문서.
- 현재 branch, `HEAD`, working tree, index 상태.
- 현재 diff, 관련 PR/Issue 상태, review 원문, unresolved thread.
- 실행한 명령, 종료 결과, Evidence, 실패 이력과 생성 또는 미생성 산출물.
- 반복 지원 작업 또는 review 대응이면 사용한 cycle 수와 제한.

관련 없는 입력은 `NOT_APPLICABLE`로 처리한다. 필요한 정보가 없으면 read-only 명령과 문서 확인으로 먼저 채운다. 확인하지 못한 원인은 사실처럼 단정하지 않는다.

## Read-only Decision Flow

1. 검증할 질문을 한 문장으로 쓴다.
2. Source of Truth, 현재 diff, review 원문, Evidence를 읽고 사실과 주장을 분리한다.
3. 문제가 실제인지, 재현되었는지, 문서 또는 완료 조건과 직접 충돌하는지 확인한다.
4. 문제가 현재 Issue 범위인지, 독립 후속 작업인지, review limit 우회인지 분리한다.
5. 현재 범위라면 가장 작은 변경 단위와 변경하지 않을 파일을 정한다.
6. 필수 중단 조건, 실패 Evidence 보존, 사람 승인 경계를 확인한다.
7. `Result Codes` 중 하나와 근거, 미확인 사항, 다음 행동을 출력한다.

이 흐름 중에는 파일 수정, stage, commit, push, PR 생성, Issue comment, merge를 수행하지 않는다.

## Decision Rules

### Validity

문제가 실제라는 판정은 원본 문서, 실행 로그, 테스트 결과, PR diff, review 원문 같은 확인 가능한 Evidence에 근거해야 한다.

Source of Truth와 현재 파일이 직접 충돌하거나, 실행 결과가 문서의 성공 판정과 충돌하거나, 완료 조건을 무효화하는 오류가 있으면 유효한 문제로 본다.

재현되지 않은 추정, 스타일 선호, 미래 개선, 원인 미확정 상태는 유효한 현재 결함으로 단정하지 않는다.

- `VERIFIED`: 현재 코드, 문서, 원본 Evidence 또는 실행 결과로 주장된 문제가 확인됨.
- `PARTIAL`: 문제 일부만 확인됐거나 일부 근거가 부족함.
- `UNVERIFIED`: 직접 확인할 근거가 부족해 결함으로 확정할 수 없음.
- `INVALID`: 주장의 전제나 현재 상태 해석이 실제 상태와 다르거나 이미 충족된 사항임.

`NOT_RUN`, `NOT_REACHED`, `NOT_APPLIED`는 실행 여부 상태이며 문제 유효성 값과 혼동하지 않는다.

### Scope

유효한 문제라도 현재 Issue의 목적과 완료 조건 안에 있을 때만 현재 작업으로 다룬다.

현재 결론, 정합성, 보안, 문서 사실성, 필수 완료 조건, merge 안전성을 무효화하지 않는 변경은 후속 작업 또는 변경 없음으로 분류한다.

- `CURRENT_SCOPE_REQUIRED`: 현재 Issue 완료를 위해 반드시 처리해야 함.
- `CURRENT_SCOPE_OPTIONAL`: 개선 가능하지만 현재 완료 조건에는 필수가 아님.
- `FOLLOW_UP_CANDIDATE`: 현재 작업과 독립적인 가치가 있는 후속 작업 후보.
- `OUT_OF_SCOPE`: 현재 Issue에서 처리하지 않는 독립 작업.
- `NO_CHANGE_REQUIRED`: 현재 상태가 이미 타당하거나 주장이 유효하지 않아 변경할 필요가 없음.

독립 후속 작업은 현재 PR이 없어도 가치가 있고, 별도 목적과 완료 조건이 있으며, 현재 PR의 review limit 회피가 목적이 아니고, 현재 PR에 병합돼야만 가치가 생기는 변경이 아니어야 한다.

HTTP endpoint, schema ownership, `ddl-auto`처럼 정책 강도가 다른 항목은 하나의 승인 조건으로 묶지 않는다. 각 항목은 `AGENTS.md`와 해당 Source of Truth의 정책을 따로 확인한다.

### Mandatory Stop

다음 조건이 확인되면 추가 판단으로 완화하지 않고 `STOP_OVERDESIGN`을 선택한 뒤 사람 결정을 요청한다.

- 지원 코드가 핵심 작업보다 커짐.
- fixture가 핵심 실험보다 커짐.
- validator를 검증하기 위한 validator가 필요함.
- fixture를 검증하기 위한 fixture가 필요함.
- 완료 조건이 작업 중 증가함.
- 같은 지원 도구 수정이 2회 한도에 도달했거나 이를 초과하려 함.
- 같은 결과를 이름만 바꿔 계속 수정함.
- review cycle 제한을 새 Issue, stacked PR, replacement PR로 우회함.

독립 가치가 있거나 검증 가능성이 높아질 수 있다는 판단은 위 필수 중단 조건을 완화하지 않는다. 일반적인 과설계 신호와 필수 중단 조건은 구분한다.

### PR Review

review finding은 현재 Issue의 완료 조건과 사실성을 기준으로 `BLOCKING`, `REQUIRED_SUPPORT`, `NON_BLOCKING`, `OUT_OF_SCOPE` 중 하나로 분류한다.

`INVALID`는 review classification이 아니라 `validity` 값이다. `validity=INVALID`인 finding은 범위에 따라 `review_classification=NON_BLOCKING` 또는 `review_classification=OUT_OF_SCOPE`로 둔다.

unresolved thread, severity label, P2 표시만으로 자동 `BLOCKING`으로 보지 않는다. 현재 결과를 무효화하는지 확인한다.

review cycle은 댓글 개수가 아니라 하나의 PR head에 대한 전체 리뷰 묶음이다. 전체 리뷰 수집, finding 판정, 사람 승인, 통합 변경 반영, 검증 후 push까지를 1 cycle로 계산한다.

최초 구현, PR 생성 전 사람 검토, read-only review 분류, `NON_BLOCKING` 또는 `OUT_OF_SCOPE` finding에 대한 변경 없는 답변, `validity=INVALID`인 finding에 대한 변경 없는 답변은 review cycle에 포함하지 않는다.

2/2 이후 `BLOCKING` 또는 `REQUIRED_SUPPORT`가 있으면 추가 내용 변경 없이 merge를 중단하고 사람 결정을 요청한다. `NON_BLOCKING`, `OUT_OF_SCOPE`, `validity=INVALID`인 finding은 추가 내용 변경 없이 근거 답변과 thread 처리 가능하며 merge를 자동 차단하지 않는다.

### Failure And Evidence

실패 후 동일 시도를 자동 반복하지 않는다. 실패 원인을 먼저 확인하고, 관련 상태가 변경됐으며, 별도 사람 승인이 있을 때만 새 작업으로 재시도한다.

실패 Evidence와 실패 상태를 입증하는 원본 산출물은 보존한다. 사람 승인으로도 실패 Evidence 삭제를 허용하지 않는다.

임시 파일이나 재생성 가능한 비-Evidence 산출물 정리는 실패 Evidence 삭제와 구분해 별도 범위로 판단한다. 실패 원인을 확정할 수 없으면 `validity=UNVERIFIED`로 판정하고, 안전하게 진행할 수 없으면 `result_code=BLOCK_CURRENT_WORK`로 판정한다.

### Minimal Change

현재 범위에서 필요한 가장 작은 파일 집합과 가장 작은 동작 변경을 선택한다.

문서 사실성 문제는 해당 Source of Truth 또는 직접 충돌한 문장만 고친다. 실험 코드 문제는 측정 대상 동작에 필요한 최소 진입점과 결과만 둔다.

unrelated refactor, 새 abstraction, 새 fixture suite, 새 문서, 새 결과 파일은 현재 판정을 성립시키는 데 필요할 때만 제안한다.

### Result Codes

- `PROCEED_MINIMAL_CHANGE`: 현재 범위에서 확인된 문제가 있고 최소 변경으로 해결할 수 있다.
- `NO_CHANGE_REQUIRED`: 문제가 실재하지 않거나 이미 충족되어 변경하지 않는다.
- `DEFER_TO_FOLLOW_UP`: 문제는 유효하지만 현재 Issue 범위 밖이라 후속 작업으로 분리한다.
- `BLOCK_CURRENT_WORK`: 현재 Evidence와 승인 범위 안에서 진행하면 사실성, 정합성, 보안, merge 안전성이 무효화된다.
- `STOP_OVERDESIGN`: 필수 중단 조건이 확인됐거나 지원 도구, fixture, validator, 문서, Evidence 확장이 핵심 질문보다 커져 사람 검토가 필요하다.

### Human Approval

read-only 판정 이후에도 branch 생성, commit, push, PR 생성, merge, repository 내용 변경, 새 Issue 생성, 새 실험 실행, profiler 실행, benchmark 실행, 권한 상승, 실패 후 재시도는 별도 승인 경계로 취급한다. 실패 후 재시도는 원인 확인과 변경된 상태 확인 뒤 별도로 승인된 새 작업일 때만 제안한다.

실패 Evidence와 실패 상태를 입증하는 원본 산출물은 사람 승인 여부와 관계없이 보존한다. 임시 파일이나 재생성 가능한 비-Evidence 산출물 정리는 실패 Evidence 삭제와 구분해 별도 작업 범위로 판단한다.

`BLOCKING` 또는 `REQUIRED_SUPPORT` 최종 확정과 review 한도 도달 후 현재 작업의 중단, 독립 재시도 여부는 사람 승인 대상으로 둔다. 사람 승인이 있어도 현재 작업의 Mandatory Stop 판정이나 review cycle 한도는 해제하지 않는다. 사람은 현재 작업 종료, 독립 재시도, 독립 후속 작업 여부를 결정할 수 있다.

승인되지 않은 작업을 판정 결과에 끼워 넣지 않는다. 변경이 필요하면 사람이 검토할 수 있도록 근거와 최소 작업만 제시한다.

## Output

다음 형식으로 짧게 출력한다.

- `question`: 검증한 질문 한 문장.
- `validity`: `VERIFIED` | `PARTIAL` | `UNVERIFIED` | `INVALID`.
- `scope_classification`: `CURRENT_SCOPE_REQUIRED` | `CURRENT_SCOPE_OPTIONAL` | `FOLLOW_UP_CANDIDATE` | `OUT_OF_SCOPE` | `NO_CHANGE_REQUIRED`.
- `result_code`: 위 Result Codes 중 하나.
- `review_classification`: `PR_REVIEW`이면 review finding 분류, 아니면 `NOT_APPLICABLE`.
- `mandatory_stop`: 확인된 필수 중단 조건 또는 없음.
- `overdesign_signals`: 확인된 일반 신호 또는 없음.
- `support_cycle`: 관련 있는 경우 사용량/제한, 관련 없으면 `NOT_APPLICABLE`.
- `workaround_detected`: `true` | `false` | `NOT_APPLICABLE`.
- `human_approval_required`: 필요한 사람 승인 또는 없음.
- `minimal_action`: 필요한 최소 변경 또는 변경 없음의 이유.
- `required_validation`: 필요한 검증 또는 없음
- `prohibited_work`: 현재 범위에서 금지할 작업 또는 없음.
- `evidence`: 확인한 파일, 명령, 로그, review 원문.
- `unknowns`: 확인하지 못한 점과 그 상태.
- `non_goals`: 현재 범위에서 제외할 작업.
- `next_step`: 구현, 보류, 후속 Issue, 사람 검토 중 하나.

상태 표현은 `VERIFIED`, `PARTIAL`, `UNVERIFIED`, `NOT_RUN`, `NOT_REACHED`, `NOT_APPLIED`, `NOT_APPLICABLE`처럼 사실 확인 수준과 실행 여부를 분리한다. `NOT_APPLICABLE`은 현재 입력 유형과 관련 없는 필드이고, `NOT_APPLIED`는 관련 작업이지만 적용하지 않은 상태다.

## Examples

1. Source of Truth와 현재 내용이 직접 충돌하고 파일 하나의 최소 수정으로 해결 가능하다. `validity=VERIFIED`, `scope_classification=CURRENT_SCOPE_REQUIRED`, `result_code=PROCEED_MINIMAL_CHANGE`.

2. P2 unresolved review지만 현재 완료 조건과 사실성, 정합성, merge 안전성을 무효화하지 않는다. `review_classification=NON_BLOCKING`, `result_code=NO_CHANGE_REQUIRED`.

3. 지원 코드 또는 fixture가 핵심 작업보다 커졌거나 review limit 우회가 확인됐다. `mandatory_stop=true`, `result_code=STOP_OVERDESIGN`, `human_approval_required=true`.

## Boundaries

- 이 Skill은 read-only triage 전용이다. 직접 repository 또는 GitHub mutation을 수행하지 않는다.
- 저장소 Source of Truth를 새로 만들지 않는다.
- 실행하지 않은 결과를 성공으로 표현하지 않는다.
- 확인하지 못한 원인을 사실처럼 단정하지 않는다.
- 현재 Issue의 완료 조건을 작업 도중 확장하지 않는다.
- branch 생성·삭제, stage, commit, amend, push, Issue·PR 생성·수정, review reply·thread resolve, merge를 수행하지 않는다.
- test, Docker, profiler, benchmark, CI를 실행하지 않는다.
