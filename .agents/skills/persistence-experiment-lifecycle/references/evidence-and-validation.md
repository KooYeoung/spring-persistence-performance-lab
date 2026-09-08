# Evidence And Validation

## Validation 전 문서

Validation을 실행하기 전에 문서 구조와 exact command를 작성할 수 있지만, 실행하지 않은 상태는 `NOT_RUN` 또는 `UNVERIFIED`로 표시한다. 예상 exception, row count, PASS와 결론을 실제 결과처럼 기록하지 않는다.

Test와 문서가 함께 변경되면 validation 전에 source identity를 기록하고 질문, fixture, transaction boundary, assertion과 cleanup 설명이 서로 일치하는지 확인한다.

## 실행 순서

1. Compile 명령을 focused test와 분리해 실행한다.
2. Compile 성공 시에만 승인된 focused test를 실행한다.
3. Full suite, benchmark, profiler 또는 JFR은 현재 질문에 별도 승인이 있을 때만 실행한다.
4. 각 명령의 exact command, invocation count, native exit code, stdout과 stderr를 보존한다.
5. 환경 문제와 source/assertion 실패를 구분한다.

현재 환경에 맞는 wrapper invocation을 사용한다. 실패 후 source나 환경 상태가 바뀌지 않았다면 자동 retry하지 않는다.

## PASS Evidence 기준

다음은 성공한 실행과 실제 assertion에서만 확정한다.

- lifecycle 및 transaction phase
- exception type, cause, SQLState와 constraint
- commit 또는 rollback 뒤 row count와 field value
- expected/unexpected row allowlist
- cleanup 대상과 remaining row
- 최종 결론과 result marker

Console의 native output은 Evidence로 사용할 수 있다. Generated report는 열지 않았다면 `GENERATED_NOT_INSPECTED`, XML·log 직접 접근은 `NOT_RUN`으로 기록한다.

## 문서 finalization

Compile과 focused test가 성공한 뒤 문서의 명령, 횟수, exit code, 관찰 수치, limitation과 결론을 실제 결과에 맞춰 갱신한다. Validation 전후 test source identity가 같음을 확인한다.

Test source와 runtime behavior가 바뀌지 않은 문서 오탈자나 사실성 표현 correction은 static verification 대상으로 다룰 수 있다. 이전 성공 Evidence를 승계하는 이유와 미실행 validation을 명시하고, 불필요한 runtime 재실행을 강제하지 않는다.

## Publication 전 검증

- Exact changed-file allowlist와 untracked file을 확인한다.
- Test와 문서의 canonical blob, encoding, EOL과 trailing whitespace를 확인한다.
- `git diff --check`를 실행한다.
- Production/API/schema/config/build/README 변경이 non-goal과 일치하는지 확인한다.
- Stage 뒤 cached diff와 검증한 working content가 같은지 확인한다.

Validation이나 Evidence가 불완전하면 PASS로 바꾸거나 publication으로 덮지 말고 중단 상태를 보고한다.
