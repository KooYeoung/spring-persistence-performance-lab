# Artifacts

M0에는 benchmark artifact가 필요하지 않다.

향후 public reproduction artifact는 작고, 공개 가능하며, approved protocol에 연결되어야 한다. 이 디렉터리에는 profiler HTML, raw stack trace, JFR file, heap dump, large log, database dump, user absolute path, secret, private artifact, private source information을 저장하지 않는다.

## EXP-001 Artifact Policy

EXP-001 official timing에는 timing과 consistency만 포함한다.

Profiler output은 official EXP-001 timing result에 포함하지 않는다. async-profiler, CPU profiling, sampled allocation profiling, JFR, heap dump, raw stack trace를 후속 외부 profiling subphase에서 수집하는 경우 official timing result와 분리하고 이 저장소에 직접 commit하지 않는다.

허용되는 artifact는 공개 가능하고, 작고, 재현 가능해야 하며, user absolute path, secret, private source information, private artifact reference가 없어야 한다.
