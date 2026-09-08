---
name: github-safe-pr-lifecycle
description: "GitHub branch·PR 게시, review finding 처리, checks와 mergeability 검증, expected-head merge, 환경 인계 및 post-merge ref/worktree cleanup을 안전하게 수행할 때 사용한다. local-only commit이나 GitHub와 무관한 파일 수정에는 사용하지 않는다."
---

# GitHub Safe PR Lifecycle

GitHub PR의 identity와 승인 경계를 보존하면서 publication부터 cleanup까지 단계별로 수행한다.

## 시작 절차

1. 현재 repository의 `AGENTS.md`, root, OS·shell, branch, upstream, worktree와 clean 상태를 확인한다.
2. `$change-scope-triage`로 요청과 review finding의 validity, scope, impact와 disposition을 판정한다.
3. PR 번호, branch, full SHA, path와 허용 mutation은 현재 요청에서 가져오며 skill에 고정하지 않는다.
4. mutation 직전에 local, upstream, remote-tracking과 GitHub identity를 fresh 확인한다.

## 필요한 reference와 도구

- PR 생성, review triage, checks, rules 또는 merge를 수행할 때는 [review-and-merge.md](references/review-and-merge.md)를 읽는다.
- 다른 환경으로 인계하거나 local sync와 source cleanup을 수행할 때는 [handoff-and-cleanup.md](references/handoff-and-cleanup.md)를 읽는다.
- body 또는 text file identity가 필요하면 `scripts/inspect_text_identity.py`를 사용한다. 이 script는 원문과 Base64 payload를 출력하거나 입력 파일을 수정하지 않는다.

## 독립 승인 경계

다음을 서로 독립적인 mutation 경계로 취급한다.

1. branch push
2. PR creation
3. review reply
4. review thread resolve
5. direct PR merge
6. auto-merge enablement or disablement
7. merge-queue enrollment or removal
8. local main synchronization
9. worktree removal
10. remote branch deletion
11. local branch deletion

한 operation의 승인은 다른 operation의 mutation 권한을 자동으로 부여하지 않는다. 같은 CLI를 사용하더라도 direct merge, auto-merge 상태 변경과 merge-queue 등록·제거는 서로 다른 GitHub state transition이므로 기존 승인을 재사용하지 않는다. 현재 요청에서 승인된 operation만 적용한다.

## 안전 불변식

- merge 직전에 expected head를 full SHA로 고정하고 REST와 GraphQL mergeability를 fresh 확인한다.
- body 비교에는 양쪽에 같은 LF와 trailing-newline 정규화 규칙을 적용하며 raw body나 전체 Base64를 출력하지 않는다.
- canonical review thread, reply 관계, `isResolved`, `isOutdated`와 모든 pagination을 확인한다.
- tool invocation, native command execution과 실제 repository/GitHub mutation을 구분해 기록한다.
- 외부 mutation 성공 여부가 불명확하면 중복 위험이 없는 read-only state 확인을 먼저 하고 자동 재시도하지 않는다.
- cleanup은 merge와 content 보존을 확인한 뒤 별도 승인으로 수행한다.
