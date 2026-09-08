# Review And Merge

## Publication gate

Push 전에 branch, base parent, local head, clean 상태, upstream, remote branch와 target-head PR을 확인한다. Push 성공 여부가 불명확하면 동일 push를 반복하기 전에 read-only ref identity를 확인한다.

PR 생성 전 title, base, head와 body를 메모리에서 확정한다. Body 비교는 expected와 actual에 같은 CRLF-to-LF 및 trailing-newline 정책을 적용한다. 원문이나 전체 Base64 대신 character count, UTF-8 byte count, SHA-256과 Base64 length를 기록한다.

PR 생성 후 state, draft, title, body, base/head full SHA, commits, changed files, additions/deletions, blobs와 requested metadata를 확인한다.

## REST와 GraphQL 역할

- REST는 PR identity, files, commits, submitted reviews, inline comments, conversation comments, check runs, suites, legacy status와 branch protection을 확인하는 데 사용한다.
- GraphQL은 canonical review threads, reply 관계, `isResolved`, `isOutdated`, review decision, mergeable, merge state와 pagination을 함께 확인하는 데 사용한다.
- Raw authenticated response나 불필요한 body를 로그에 남기지 않고 최소 projection을 사용한다.
- 모든 connection의 `hasNextPage`를 확인한다. `true`이면 조회되지 않은 finding이 없다고 가정하지 않는다.

## Finding 분류

Repository의 review classification인 `BLOCKING`, `REQUIRED_SUPPORT`, `NON_BLOCKING`, `OUT_OF_SCOPE`는 `AGENTS.md`의 정의와 우선순위를 그대로 따른다. 분석할 때는 다음 축을 서로 섞지 않고 함께 기록한다.

- validity: `VERIFIED`, `PARTIAL`, `INVALID`, `UNVERIFIED`
- scope/support: `CURRENT_SCOPE_REQUIRED`, `REQUIRED_SUPPORT`, `OUT_OF_SCOPE`
- merge impact: `BLOCKING`, `NON_BLOCKING`
- disposition: source correction, reply and resolve, defer to post-merge maintenance, manual triage

`REQUIRED_SUPPORT`를 `BLOCKING` 또는 `NON_BLOCKING`으로 덮어쓰지 않는다. 위 분석 축은 repository의 review classification을 대체하거나 새 taxonomy를 만들기 위한 것이 아니다.

Validity는 필요한 Evidence가 확인되면 `VERIFIED`, 일부만 확인되면 `PARTIAL`, finding이 실제 상태와 맞지 않으면 `INVALID`, 판단할 Evidence가 확보되지 않으면 `UNVERIFIED`로 기록한다. `PARTIAL`은 미확정 범위를 그대로 보존한다. 그 범위가 현재 mutation의 필수 gate이면 차단하고, 보조 snapshot에만 해당하면 다른 gate를 독립적으로 판정한다. `PARTIAL`을 `VERIFIED`로 승격하거나 누락하지 않는다.

Unresolved 상태나 severity 이름만으로 blocking을 결정하지 않는다. 현재 head의 사실성, 정합성, 보안 또는 완료 조건을 실제로 무효화하는지 판단한다. Formal `CHANGES_REQUESTED`가 없어도 verified current-scope finding은 blocking일 수 있다.

Finding correction은 source push, inline reply와 exact thread resolve를 각각 별도 mutation으로 기록한다. 새로운 head의 review summary와 thread 상태는 fresh snapshot에서 다시 확인한다.

## Checks와 rules

- `no checks reported`를 실제 check failure와 구분한다.
- Head check runs, check suites, legacy commit status, base branch protection, required contexts/checks와 repository rulesets을 각각 확인한다.
- Required protection이나 ruleset이 없으면 외부 queued 또는 conclusion 없는 suite를 자동 blocker로 취급하지 않는다.
- Required review, check 또는 ruleset이 있으면 충족 여부를 별도로 판정한다.

## Mergeability와 merge

Merge 직전에 open, non-draft, exact base/head, no auto-merge와 actionable finding 부재를 확인한다. REST mergeable이 `true`이고 GraphQL mergeable이 `MERGEABLE`인 것은 필수다. REST mergeable state와 GraphQL merge state는 checks, rules, review와 update 상태까지 반영할 수 있는 별도 Evidence로 판정한다.

REST `clean`과 GraphQL `CLEAN`은 merge-state gate를 통과한다. REST `unstable` 또는 GraphQL `UNSTABLE`은 원인이 non-required check 또는 suite이고, required protection·check·review·ruleset 미충족과 actionable finding이 없으며, identity·expected-head guard와 REST·GraphQL mergeability가 모두 통과했음이 확인된 경우에만 비차단으로 판정할 수 있다. Optional check를 무시하지 않고 required 여부와 실제 merge safety를 분리해 기록한다.

`UNSTABLE` 원인이 불명확하거나 required condition과 관련되면 차단한다. REST와 GraphQL projection이 다르면 required/optional check Evidence로 차이를 설명할 수 있어야 하며, 원인을 확정할 수 없으면 차단한다. REST `null` 또는 unknown, GraphQL `UNKNOWN`, conflict, required update나 다른 필수 조건 미확정, pagination, pending review summary 또는 identity mismatch가 있으면 merge하지 않는다. Base update 직후 recalculation 가능성은 별도 승인된 fresh recovery에서만 다시 확인한다.

Merge 직전에 current PR head가 승인된 expected full SHA와 일치해야 한다. Merge command 또는 API가 expected-head guard를 지원하면 반드시 사용한다. Guard를 사용할 수 없거나 expected SHA를 확정할 수 없으면 merge하지 않는다. 다른 merge endpoint나 보호되지 않은 fallback으로 우회하지 않는다. 새 head가 생기면 기존 승인을 재사용하지 않고 review와 readiness를 fresh 확인한다.

Auto, admin, 다른 merge method, branch deletion과 retry는 별도 승인이 없으면 추가하지 않는다.

## Post-merge verification

Merge 직후 PR state, merged time와 merge SHA를 확인하고 merge commit의 parent, subject, changed files, stats와 content blobs를 검증한다. Original base/head, body와 review/thread snapshot, source branch 보존도 확인한다.

Terminal `MERGED` 상태에서 mergeability가 `UNKNOWN`으로 보이는 것은 pre-merge gate의 확정된 Evidence와 구분한다. Post-verification 실패가 있어도 merge를 자동으로 되돌리거나 보정하지 않는다.
