---
name: change-scope-triage
description: 코드, 문서, 실험, 지원 도구 변경 전 read-only로 문제 실재 여부, 현재 범위 필요성, 최소 변경, 과설계, 중단 또는 보류 여부와 PR review finding 분류를 판단할 때 사용합니다.
---

## Purpose

변경을 시작하기 전에 현재 요청이 실제로 수정이 필요한 문제인지 read-only로 판정한다.

이 Skill은 코드, 문서, 실험, 지원 도구, Evidence, PR review 대응의 범위를 좁히기 위한 의사결정 절차다. 파일 수정, stage, commit, push, PR 생성, merge를 수행하지 않는다. 판정 결과는 이후 작업자가 최소 변경으로 진행하거나, 변경하지 않거나, 후속 Issue로 분리하거나, 현재 작업을 중단하는 근거가 된다.

## Use This Skill When

- 코드, 문서, 실험 결과, 스크립트, fixture, validator를 변경하기 전에 문제 실재 여부를 확인해야 한다.
- PR review comment, unresolved thread, CI 실패, 문서 불일치가 현재 Issue 범위에서 반드시 고쳐야 하는지 판단해야 한다.
- 제안된 수정이 Source of Truth, 완료 조건, Evidence 원칙과 충돌하는지 확인해야 한다.
- 지원 도구 수정, 재시도, 추가 validator, 새 실험, 새 문서 생성이 과설계인지 판단해야 한다.
- 현재 작업을 계속할지, 보류할지, 사람 검토로 넘길지 결정해야 한다.

## Required Context

- 현재 사용자 요청, Issue 목적, 완료 조건, Non-goal.
- `AGENTS.md`와 저장소의 Source of Truth 문서.
- 현재 branch, `HEAD`, working tree, index 상태.
- 이미 실행한 명령, Evidence, 산출물 생성 여부, 실패 이력.
- `PR_REVIEW` 입력이면 관련 PR diff, review comment, unresolved thread, severity.
- `FAILURE_ANALYSIS` 또는 실제 실행 결과 관련 입력이면 CI 또는 실행 로그.
- 리뷰 또는 반복 지원 작업 관련 입력이면 PR 상태와 support cycle 사용량.

관련 없는 입력은 `NOT_APPLICABLE`로 처리한다. 필요한 정보가 없으면 read-only 명령과 문서 확인으로 먼저 채운다. 확인하지 못한 원인은 사실처럼 단정하지 않는다.

## Read-only Decision Flow

1. 검증할 질문을 한 문장으로 쓴다.
2. Source of Truth, 현재 diff, review 원문, Evidence를 읽고 사실과 주장을 분리한다.
3. 문제가 실제인지, 재현되었는지, 문서 또는 완료 조건과 직접 충돌하는지 확인한다.
4. 문제가 현재 Issue 범위에 포함되는지 판단한다.
5. 현재 범위라면 가장 작은 변경 단위와 변경하지 않을 파일을 정한다.
6. 지원 도구, fixture, validator, 새 실험이 핵심 질문보다 커지는지 확인한다.
7. 아래 Result Codes 중 하나와 근거를 출력한다.

이 흐름 중에는 파일을 수정하지 않는다. 필요한 변경은 출력의 `minimal_action`에만 적는다.

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

새 실험, 새 benchmark, profiler smoke, HTTP endpoint, schema ownership 변경, `ddl-auto` 변경은 해당 Issue와 명시 승인이 없으면 현재 범위가 아니다.

- `CURRENT_SCOPE_REQUIRED`: 현재 Issue 완료를 위해 반드시 처리해야 함.
- `CURRENT_SCOPE_OPTIONAL`: 개선 가능하지만 현재 완료 조건에는 필수가 아님.
- `FOLLOW_UP_CANDIDATE`: 현재 작업과 독립적인 가치가 있는 후속 후보.
- `OUT_OF_SCOPE`: 현재 Issue에서 처리하지 않는 독립 작업.
- `NO_CHANGE_REQUIRED`: 현재 상태가 이미 타당하거나 주장이 유효하지 않아 변경할 필요가 없음.

### PR Review

review finding은 현재 Issue의 완료 조건과 사실성을 기준으로 `BLOCKING`, `REQUIRED_SUPPORT`, `NON_BLOCKING`, `OUT_OF_SCOPE` 중 하나로 분류한다.

unresolved thread, severity label, P2 표시만으로 자동 `BLOCKING`으로 보지 않는다. 현재 결과를 무효화하는지 확인한다.

review가 맞지만 현재 Issue와 독립이면 후속 작업으로 넘긴다. review가 사실과 다르거나 이미 충족되었으면 변경 없이 근거를 남긴다.

### Overdesign

외부 명령 한두 개로 충분한 일을 애플리케이션 내부 framework로 옮기지 않는다.

validator를 검증하기 위한 새 validator, 단일 실험을 위한 범용 결과 lifecycle framework, Git 또는 Docker 제어 코드를 애플리케이션 소스에 추가하는 흐름은 과설계로 본다.

지원 코드나 fixture가 핵심 실험보다 커지거나, 문서 또는 Evidence 수가 늘어도 검증 가능성이 좋아지지 않으면 중단을 검토한다.

과설계 신호 하나만으로 자동으로 `STOP_OVERDESIGN`을 선택하지 않는다. 제안된 구조가 없으면 실제 오류가 발생하는지, 현재 완료 조건에 필수인지, 기존 코드, 문서, 명령 또는 사람 확인으로 대체 가능한지, 현재 작업과 독립적인 가치가 있는지, 추가 복잡성이 검증 가능성을 실제로 높이는지 함께 확인한다.

`STOP_OVERDESIGN`은 지원 구조가 핵심 문제보다 커지고 더 단순한 대안이 있는데도 계속 확장해야 하는 경우에 사용한다.

### Support Cycle

같은 지원 도구 수정은 최대 2회, 같은 문제의 리뷰 사이클은 최대 2회로 제한한다.

횟수 제한에 도달하면 같은 내용 변경은 동결한다. 세 번째 직접 amend, 새 Issue, stacked PR, replacement PR로 같은 결과를 완성하려는 우회도 금지한다.

횟수 도달은 PR 전체 자동 중단을 뜻하지 않는다. 실제 `BLOCKING`이면 PR을 중단하고 사람 결정을 요청하고, 비차단 finding이면 추가 변경 없이 현재 결과를 유지한다.

실패 후 동일 시도를 자동 반복하지 않는다. 실패 원인을 먼저 확인하고, 관련 상태가 바뀌었으며, 별도 사람 승인이 있을 때만 새 작업으로 재시도한다. 실패 Evidence를 삭제하거나 성공 Evidence로 덮어쓰지 않는다.

### Minimal Change

현재 범위에서 필요한 가장 작은 파일 집합과 가장 작은 동작 변경을 선택한다.

문서 사실성 문제는 해당 Source of Truth 또는 직접 충돌한 문장만 고친다. 실험 코드 문제는 측정 대상 동작에 필요한 최소 진입점과 결과만 둔다.

unrelated refactor, 새 abstraction, 새 fixture suite, 새 문서, 새 결과 파일은 현재 판정을 성립시키는 데 필요할 때만 제안한다.

### Result Codes

- `PROCEED_MINIMAL_CHANGE`: 현재 범위에서 확인된 문제가 있고 최소 변경으로 해결할 수 있다.
- `NO_CHANGE_REQUIRED`: 문제가 실재하지 않거나 이미 충족되어 변경하지 않는다.
- `DEFER_TO_FOLLOW_UP`: 문제는 유효하지만 현재 Issue 범위 밖이라 후속 작업으로 분리한다.
- `BLOCK_CURRENT_WORK`: 현재 Evidence와 승인 범위 안에서 진행하면 사실성, 정합성, 보안, merge 안전성이 무효화된다.
- `STOP_OVERDESIGN`: 지원 도구, fixture, validator, 문서, Evidence 확장이 핵심 질문보다 커져 사람 검토가 필요하다.

### Human Approval

read-only 판정 이후에도 branch 생성, commit, push, PR 생성, merge, 새 실험 실행, profiler 실행, benchmark 실행, 권한 상승, 실패 후 재시도, 실패 산출물 삭제는 별도 승인 경계로 취급한다. 실패 후 재시도는 원인 확인과 변경된 상태 확인 뒤 별도로 승인된 새 작업일 때만 제안한다.

승인되지 않은 작업을 판정 결과에 끼워 넣지 않는다. 변경이 필요하면 사람이 검토할 수 있도록 근거와 최소 작업만 제시한다.

## Output

다음 형식으로 짧게 출력한다.

- `question`: 검증한 질문 한 문장.
- `validity`: `VERIFIED` | `PARTIAL` | `UNVERIFIED` | `INVALID`.
- `scope_classification`: `CURRENT_SCOPE_REQUIRED` | `CURRENT_SCOPE_OPTIONAL` | `FOLLOW_UP_CANDIDATE` | `OUT_OF_SCOPE` | `NO_CHANGE_REQUIRED`.
- `result_code`: 위 Result Codes 중 하나.
- `review_classification`: 해당하면 review finding 분류, 없으면 `NOT_APPLIED`.
- `overdesign_signals`: 확인된 신호 또는 없음.
- `support_cycle`: 관련 있는 경우 사용량/제한, 관련 없으면 `NOT_APPLICABLE`.
- `workaround_detected`: `true` | `false` | `NOT_APPLICABLE`.
- `human_approval_required`: 필요한 사람 승인 또는 없음.
- `minimal_action`: 필요한 최소 변경 또는 변경 없음의 이유.
- `evidence`: 확인한 파일, 명령, 로그, review 원문.
- `unknowns`: 확인하지 못한 점과 그 상태.
- `non_goals`: 현재 범위에서 제외할 작업.
- `next_step`: 구현, 보류, 후속 Issue, 사람 검토 중 하나.

상태 표현은 `VERIFIED`, `PARTIAL`, `UNVERIFIED`, `NOT_RUN`, `NOT_REACHED`, `NOT_APPLIED`, `BLOCKED`처럼 사실 확인 수준과 실행 여부를 분리한다.

## Examples

1. Source of Truth와 직접 충돌해 파일 하나 최소 수정

   `README.md`가 공식 benchmark를 성공으로 설명하지만 `results/`의 원본 Evidence가 `NOT_RUN`이면 문서 사실성 문제가 실제다. 현재 Issue가 문서 정합성 보정이면 직접 충돌한 문장 하나만 고치는 최소 변경으로 진행한다.
   판정: `validity=VERIFIED`, `scope=CURRENT_SCOPE_REQUIRED`, `result=PROCEED_MINIMAL_CHANGE`.

2. P2 unresolved review지만 변경 불필요

   review가 스크립트 변수명 개선을 제안했지만 현재 Issue의 완료 조건, 공식 결론, 정합성, 보안, merge 안전성을 무효화하지 않으면 unresolved 상태만으로 차단하지 않는다. 근거를 남기고 변경하지 않는다.
   판정: `review_classification=NON_BLOCKING`, `current_change_required=false`, `result=NO_CHANGE_REQUIRED`.

3. support cycle 소진 후 같은 변경 우회 시도

   같은 helper 수정과 review 대응이 이미 2회를 채웠는데 새 이름의 validator를 추가해 같은 문제를 다시 우회하려면 현재 작업을 중단한다. 실패 이력과 횟수 제한을 남기고 사람 검토로 넘긴다.
   판정: `workaround_detected=true`, `result=STOP_OVERDESIGN`.

## Boundaries

- 이 Skill은 read-only triage 전용이다. 직접 파일을 고치거나 Git 상태를 바꾸지 않는다.
- 저장소 Source of Truth를 새로 만들지 않는다.
- 실행하지 않은 결과를 성공으로 표현하지 않는다.
- 확인하지 못한 원인을 사실처럼 단정하지 않는다.
- 현재 Issue의 완료 조건을 작업 도중 확장하지 않는다.
- push, PR 생성, merge, Issue comment, 새 Issue 생성은 수행하지 않는다.
