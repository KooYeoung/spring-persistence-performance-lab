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

Remote branch deletion 승인은 remote 이름이 아니라 canonical PR head repository, fully qualified head ref, expected full SHA와 verified source remote의 조합에 부여한다. Mutation 전에 PR head repository identity, head ref와 branch ownership을 fresh 확인하고, source branch의 configured upstream remote/ref와 각 remote의 effective push URL을 대조해 source remote를 확정한다. Effective push URL은 credential-bearing value를 출력하지 않고 HTTPS, SSH, scp-style 및 optional `.git` suffix 차이를 정규화한 canonical `(host, owner, repository)` identity로 비교한다. 하나의 remote에 push destination이 여러 개라면 모두 승인된 head repository로 귀결되어야 한다.

Configured upstream이 있으면 해당 remote/ref가 PR head repository/ref와 일치할 때만 사용한다. Upstream이 없으면 remote 이름을 추정하지 않고 canonical identity로 유일하게 일치하며 현재 승인 범위에 포함된 remote만 선택한다. Upstream 충돌, candidate 부재 또는 upstream으로 해소되지 않는 복수 candidate가 있으면 삭제를 중단하고 사용자 확인을 요청한다. Fork PR에서는 base repository remote가 아닌 head fork repository를 가리키는 remote가 필요하며, 해당 remote가 local에 없으면 GitHub API deletion으로 우회하지 않는다.

Cleanup gate에서 승인된 repository/ref, expected full SHA와 resolved remote를 deletion identity로 고정하고 삭제 직전에 같은 remote의 tip을 확인한다. `<verified-source-remote>`는 이 identity gate에서 실행 전에 확정한 concrete remote name이며 `origin`의 단순 별칭이 아니다. Read-then-delete 확인만으로 안전하다고 판정하지 않으며, 삭제 요청 자체에 다음과 동등한 explicit lease를 적용한다.

```sh
git push \
  --force-with-lease=refs/heads/<branch>:<expected-full-sha> \
  <verified-source-remote> \
  :refs/heads/<branch>
```

Implicit remote-tracking state에 의존하는 lease는 사용하지 않는다. 같은 resolved remote를 tip 확인, lease deletion과 post-delete 확인에 재사용한다. Remote tip이 expected SHA와 다르거나 lease가 거부되면 즉시 중단한다. Remote ref가 이미 없다면 `NO_CHANGE_REQUIRED` 또는 동등한 no-op으로 기록하고 ref를 재생성하지 않는다. Configured automatic deletion과 operator가 실행하는 explicit deletion을 구분하며, 이 explicit lease는 후자에만 적용되는 승인된 branch deletion의 compare-and-delete 보호 수단일 뿐 history rewrite 권한이 아니다.

승인된 경우 다음 순서로 진행한다.

1. Force 없이 source worktree를 제거하고 registration과 physical path 부재를 확인한다.
2. Expected source tip에 고정된 explicit lease로 remote branch를 삭제한다.
3. 다음과 동등한 명령으로 삭제에 사용한 같은 resolved remote의 head를 확인하고, GitHub ref와 해당 remote namespace의 remote-tracking ref 부재도 확인한다.

   ```sh
   git ls-remote --heads \
     <verified-source-remote> \
     refs/heads/<branch>
   ```

4. 그 뒤에만 local source branch를 삭제한다.

Remote branch deletion과 local branch deletion은 서로 독립적인 mutation 승인 경계로 유지한다. 성공 후 같은 resolved remote를 사용한 `git ls-remote`, GitHub ref와 해당 remote namespace의 remote-tracking ref 부재를 확인한 뒤에만 local branch deletion으로 진행한다.

한 단계가 실패하면 다음 destructive target으로 진행하지 않는다. Unconditional `git push <verified-source-remote> --delete <branch>`, `--force`, `+refspec`, GitHub API delete fallback, retry, force removal, manual ref deletion, prune, reset 또는 backup ref 생성으로 우회하지 않는다. Backup ref를 만들지 않았다면 삭제된 source commit의 장기 복구 가능성을 보장하지 않는다고 기록한다.

## 실행과 mutation 기록

Tool call이 shell 실행 전에 거부됐는지, native command가 실제 실행됐는지, repository 또는 GitHub state가 바뀌었는지를 구분한다. Tool-level verification failure 뒤 zero-mutation을 확인한 경우에만 동일 승인 범위에서 안전한 command formatting correction 가능성을 판단한다.

외부 mutation이 성공했는지 불명확하면 duplicate PR, comment, push 또는 merge를 피하기 위해 read-only state부터 확인하고 새 승인 없이는 재시도하지 않는다.
