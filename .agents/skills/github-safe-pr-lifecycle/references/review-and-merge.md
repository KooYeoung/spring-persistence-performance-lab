# Review And Merge

## Publication gate

Push 전에 branch, base parent, local head, clean 상태, upstream, remote branch와 target-head PR을 확인한다. Push 성공 여부가 불명확하면 동일 push를 반복하기 전에 read-only ref identity를 확인한다.

PR 생성 전 title, base, head와 body를 메모리에서 확정한다. Body 비교는 expected와 actual에 같은 CRLF-to-LF 및 trailing-newline 정책을 적용한다. 원문이나 전체 Base64 대신 character count, UTF-8 byte count, SHA-256과 Base64 length를 기록한다.

PR 생성 후 state, draft, title, body, base/head full SHA, commits, changed files, additions/deletions, blobs와 requested metadata를 확인한다.

## REST와 GraphQL 역할

- REST는 PR identity, files, commits, submitted reviews, inline comments, conversation comments, check runs, suites, legacy status와 branch protection을 확인하는 데 사용한다.
- GraphQL은 canonical review threads, reply 관계, `isResolved`, `isOutdated`, review decision, mergeable, merge state와 pagination을 함께 확인하는 데 사용한다.
- Raw authenticated response나 불필요한 body를 로그에 남기지 않고 최소 projection을 사용한다.
- Identity, review, finding, check·rule과 open-work 판정에 사용하는 REST collection은 `Link` pagination을 끝까지 따르거나 `gh api --paginate`와 동등한 방법으로 모든 page를 수집한다. 첫 page나 `per_page` 최대값만으로 전체 결과라고 가정하지 않는다.
- REST가 여러 JSON page를 반환하면 `--slurp` 또는 동등한 aggregation을 사용하고 실제 response shape에 맞게 flatten한 뒤 count와 classification을 수행한다. 수집한 page 수와 completeness를 기록한다.
- 필수 gate의 REST pagination 또는 aggregation이 실패하면 미확정 범위를 `PARTIAL` 또는 `UNVERIFIED`로 보존하고 해당 mutation을 차단한다. 보조 snapshot만 불완전하면 그 범위를 보존하고 다른 gate를 독립적으로 판정한다.
- 단일 resource endpoint에는 pagination을 요구하지 않는다.
- GraphQL collection은 `pageInfo.hasNextPage`와 `endCursor`로 모든 page를 소진한다. Pagination이 남아 있으면 조회되지 않은 finding이 없다고 가정하지 않는다.

## Finding 분류

Finding 분류는 repository의 authoritative `$change-scope-triage`와 `AGENTS.md` taxonomy를 값의 누락이나 재분류 없이 따른다. Validity, scope, review classification 또는 support, merge impact와 disposition을 서로 독립된 축으로 기록하며, 이 reference의 일부 예시를 exhaustive enum으로 사용하지 않는다.

Evidence가 일부만 확인된 상태는 authoritative `PARTIAL`로 보존한다. 미확정 범위가 현재 mutation의 필수 gate이면 차단하고, 보조 snapshot에만 해당하면 다른 gate를 독립적으로 판정한다. `PARTIAL`을 확정 상태로 승격하거나 누락하지 않으며, `REQUIRED_SUPPORT`를 scope나 merge impact로 재분류하지 않는다.

Unresolved 상태나 severity 이름만으로 blocking을 결정하지 않는다. 현재 head의 사실성, 정합성, 보안 또는 완료 조건을 실제로 무효화하는지 판단한다. Formal `CHANGES_REQUESTED`가 없어도 verified current-scope finding은 blocking일 수 있다.

Finding correction은 source push, inline reply와 exact thread resolve를 각각 별도 mutation으로 기록한다. 새로운 head의 review summary와 thread 상태는 fresh snapshot에서 다시 확인한다.

## Checks와 rules

- `no checks reported`를 실제 check failure와 구분한다.
- Head check runs, check suites, legacy commit status, base branch protection, required contexts/checks와 repository rulesets을 각각 확인한다.
- Required protection이나 ruleset이 없으면 외부 queued 또는 conclusion 없는 suite를 자동 blocker로 취급하지 않는다.
- Required review, check 또는 ruleset이 있으면 충족 여부를 별도로 판정한다.
- Merge mutation 전에 base branch protection과 ruleset에서 required merge queue 존재 여부와 queue가 허용하는 merge method를 확인한다. 이 projection이 `PARTIAL`, `UNVERIFIED`, unknown이거나 서로 모순되면 merge 관련 mutation을 차단한다.
- Direct merge 또는 eventual terminal merge를 예약하는 auto-merge·merge-queue mutation 전에 repository의 automatic head-branch deletion 설정, PR head repository ownership, source branch preservation 요구와 deletion side effect의 명시적 승인 여부를 확인한다. Same-repository head에서 automatic deletion이 활성화됐고 source 보존이 필요하거나 side effect가 승인되지 않았다면 해당 mutation을 차단한다. 보존 요구가 없고 configured deletion이 명시적으로 승인됐다면 다른 gate 통과를 전제로 진행할 수 있다. Fork-owned head에는 base repository 설정이 동일하게 적용된다고 추정하지 않고 ownership과 적용 범위를 확인한다.
- Automatic deletion은 operator가 실행한 explicit remote-delete command와 구분되는 configured merge side effect로 기록한다. Terminal merge 후 remote ref가 이미 없다면 cleanup에서 `NO_CHANGE_REQUIRED`로 처리하고 ref를 재생성하지 않는다. Cleanup reference의 explicit expected-SHA lease는 operator가 remote deletion을 직접 수행할 때만 적용한다.

## Mergeability와 merge

Merge 직전에 open, non-draft, exact base/head, no auto-merge와 actionable finding 부재를 확인한다. REST mergeable이 `true`이고 GraphQL mergeable이 `MERGEABLE`인 것은 필수다. REST mergeable state와 GraphQL merge state는 checks, rules, review와 update 상태까지 반영할 수 있는 별도 Evidence로 판정한다.

REST `clean`과 GraphQL `CLEAN`은 merge-state gate를 통과한다. REST `unstable` 또는 GraphQL `UNSTABLE`은 원인이 non-required check 또는 suite이고, required protection·check·review·ruleset 미충족과 actionable finding이 없으며, identity·expected-head guard와 REST·GraphQL mergeability가 모두 통과했음이 확인된 경우에만 비차단으로 판정할 수 있다. Optional check를 무시하지 않고 required 여부와 실제 merge safety를 분리해 기록한다.

`UNSTABLE` 원인이 불명확하거나 required condition과 관련되면 차단한다. REST와 GraphQL projection이 다르면 required/optional check Evidence로 차이를 설명할 수 있어야 하며, 원인을 확정할 수 없으면 차단한다. REST `null` 또는 unknown, GraphQL `UNKNOWN`, conflict, required update나 다른 필수 조건 미확정, pagination, pending review summary 또는 identity mismatch가 있으면 merge하지 않는다. Base update 직후 recalculation 가능성은 별도 승인된 fresh recovery에서만 다시 확인한다.

Merge 직전에 current PR head가 승인된 expected full SHA와 일치해야 한다. Merge command 또는 API가 expected-head guard를 지원하면 반드시 사용한다. Guard를 사용할 수 없거나 expected SHA를 확정할 수 없으면 direct merge와 merge-queue enrollment를 모두 차단한다. 다른 merge endpoint나 보호되지 않은 fallback으로 우회하지 않는다. 새 head가 생기면 기존 승인을 재사용하지 않고 review와 readiness를 fresh 확인한다.

Required merge queue가 없을 때만 승인된 merge method와 expected-head guard를 결합한 direct merge 흐름을 사용한다. Queue가 required이면 required checks 통과 후 queue enrollment가, checks pending 중에는 auto-merge enablement가 발생할 수 있음을 구분하며, direct merge·queue enrollment·auto-merge enablement는 각각 별도 승인을 요구한다. Queue가 정한 merge method가 승인된 의도와 다르거나 불명확하면 enqueue하지 않는다.

Queue 또는 auto-merge command 성공을 merge 완료로 간주하지 않는다. 성공 직후 PR state를 fresh 확인해 `queued`, `auto-merge pending`, `merged`, `rejected` 또는 `removed`로 구분하고, `queued`나 `auto-merge pending`을 `merged`로 기록하지 않는다. Terminal `MERGED`가 확인되기 전에는 merge commit, main update, content identity나 cleanup을 post-merge 완료로 판정하지 않는다.

Queue 대기, polling, terminal merge 확인, local main synchronization과 cleanup은 각각 별도 승인 범위다. `--admin`은 branch protection과 merge queue를 우회하는 별도 고위험 mutation이며 fallback으로 사용하지 않는다. Queue가 required가 아니면 기존 direct-merge 흐름을 유지한다.

Auto-merge 상태 변경, merge-queue enrollment·removal, admin bypass, 다른 merge method, branch deletion과 retry는 별도 승인이 없으면 추가하지 않는다.

## Post-merge verification

Merge 직후 PR state, merged time와 merge SHA를 확인하고 merge commit의 parent, subject, changed files, stats와 content blobs를 검증한다. Original base/head, body와 review/thread snapshot, 승인된 preservation/deletion outcome과 실제 source-ref 상태도 확인한다.

Terminal `MERGED` 상태에서 mergeability가 `UNKNOWN`으로 보이는 것은 pre-merge gate의 확정된 Evidence와 구분한다. Post-verification 실패가 있어도 merge를 자동으로 되돌리거나 보정하지 않는다.
