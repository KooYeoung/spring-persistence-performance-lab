# Artifacts

M0에는 benchmark artifact가 필요하지 않다.

향후 public reproduction artifact는 작고, 공개 가능하며, approved protocol에 연결되어야 한다.

Git에 포함되는 tracked artifact에는 profiler HTML, raw stack trace, JFR, collapsed stack, raw response, log, heap dump, database dump, local absolute path, secret, private artifact, private source information을 저장하지 않는다.

## Git에서 추적하지 않는 로컬 artifact

승인된 profiler protocol이 생성한 local raw artifact는 `artifacts/exp-001/profiling/<profile-run-id>/`에 둘 수 있다. 이 경로의 raw artifact는 Git 추적 대상이 아니며 publication 결과가 아니고, 공개 evidence로 자동 승격하지 않는다. 기존 `.gitignore`와 profiler 문서의 정책을 따른다.

## EXP-001 Artifact Policy

EXP-001 official timing에는 timing과 consistency만 포함한다.

Profiler output은 official EXP-001 timing result에 포함하지 않는다. async-profiler, CPU profiling, sampled allocation profiling, JFR, heap dump, raw stack trace를 후속 외부 profiling subphase에서 수집하는 경우 official timing result와 분리하고 이 저장소에 직접 commit하지 않는다.

허용되는 artifact는 공개 가능하고, 작고, 재현 가능해야 하며, user absolute path, secret, private source information, private artifact reference가 없어야 한다.
