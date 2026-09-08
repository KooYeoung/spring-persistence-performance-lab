# Handoff And Cleanup

## 환경 전환 handoff

현재 OS와 shell에서 repository root를 다시 확인한다. 이전 장비나 운영체제의 절대 경로를 현재 gate에 그대로 적용하지 않는다. 경로 차이만으로 repository corruption을 판정하지 않는다.

다음 정보를 전달한다.

- repository URL
- current branch와 full SHA
- upstream과 ahead/behind
- clean/dirty 상태와 exact changed files
- registered worktree inventory
- remote-tracking 및 GitHub branch와 PR 상태
- 완료한 validation의 exact command와 결과
- 실행하지 않은 validation
- 다음에 허용된 mutation 경계

Secret, token, credential, raw authenticated response와 불필요한 절대 경로는 전달하지 않는다.

Stale remote-tracking ref는 GitHub remote head가 실제로 없는지 먼저 확인하고, 별도 승인된 reconciliation에서만 현재 환경에 맞는 prune을 수행한다.

## Post-merge local sync

1. GitHub main, merged PR과 merge commit content identity를 확인한다.
2. Local main과 worktree가 clean한지 확인한다.
3. 승인된 explicit fetch로 remote-tracking main만 갱신한다.
4. Behind 관계와 fast-forward 가능성을 검증한다.
5. 승인된 fast-forward만 수행하고 새 local merge commit이 생기지 않았는지 확인한다.

Fetch, pull, rebase와 reset을 상호 대체 가능한 fallback으로 취급하지 않는다.

## Source cleanup

Squash merge에서는 source commit의 direct ancestry를 cleanup 조건으로 사용하지 않는다. PR merge identity와 merged content blobs가 보존됐는지 확인한다.

Cleanup 전 다음을 확인한다.

- Main local/upstream/GitHub identity와 clean 상태
- Source local/upstream/remote/GitHub full SHA
- Worktree의 canonical path, clean 상태와 branch attachment
- Source path가 main root가 아니고 main 내부도 아닌지 여부
- Open work, tags, locks와 unrelated refs/worktrees

승인된 경우 다음 순서로 진행한다.

1. Force 없이 source worktree를 제거하고 registration과 physical path 부재를 확인한다.
2. Expected source tip을 다시 확인하고 remote branch를 삭제한다.
3. Remote head와 remote-tracking ref 부재를 확인한다.
4. 그 뒤에만 local source branch를 삭제한다.

한 단계가 실패하면 다음 destructive target으로 진행하지 않는다. Force removal, force push, manual ref deletion, prune, reset 또는 backup ref 생성으로 자동 복구하지 않는다. Backup ref를 만들지 않았다면 삭제된 source commit의 장기 복구 가능성을 보장하지 않는다고 기록한다.

## 실행과 mutation 기록

Tool call이 shell 실행 전에 거부됐는지, native command가 실제 실행됐는지, repository 또는 GitHub state가 바뀌었는지를 구분한다. Tool-level verification failure 뒤 zero-mutation을 확인한 경우에만 동일 승인 범위에서 안전한 command formatting correction 가능성을 판단한다.

외부 mutation이 성공했는지 불명확하면 duplicate PR, comment, push 또는 merge를 피하기 위해 read-only state부터 확인하고 새 승인 없이는 재시도하지 않는다.
