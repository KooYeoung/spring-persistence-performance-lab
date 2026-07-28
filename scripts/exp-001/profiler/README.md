# EXP-001 Async-profiler Harness

이 harness는 EXP-001 Phase B evidence 수집용이다.

실험 질문: 동일한 공개 구현에서 50,000건 저장을 수행할 때 JPA `saveAll` 경로와 JDBC batch 경로의 elapsed time 차이는 CPU sample과 sampled allocation 관점에서 어떤 원인 후보를 보이는가?

## 경계

- 기존 official timing result `results/exp-001/20260727T053643Z-2d76b26`는 읽기 전용 guard 대상으로만 사용한다.
- 이 harness는 official elapsed result를 갱신하지 않는다.
- Java source는 Phase B harness 구현 범위에서 변경하지 않는다.
- Native Windows async-profiler attach는 지원하지 않는다. Primary runtime은 Docker Desktop Linux x64 container이다.
- Actual 50,000-row profile execution은 smoke 통과 후 별도 명시 실행에서만 허용한다.
- Raw JFR, HTML, collapsed stack, response raw, profiler log는 Git에 추가하지 않는다.

## Tool Pin

`scripts/exp-001/tools/async-profiler.lock`가 async-profiler `4.5` Linux x64 asset을 고정한다.

- asset: `async-profiler-4.5-linux-x64.tar.gz`
- SHA-256: `89546fbb9ee0fc5496c7edd4099b0709489bc78b0d8057ccbb4b801f6b032b62`
- install path: `scripts/exp-001/.tools/async-profiler/linux-x64/4.5/async-profiler-4.5-linux-x64`
- executable: `bin/asprof`
- converter: `bin/jfrconv`

Binary는 commit하지 않는다. 다운로드가 필요한 경우에만 다음처럼 명시한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\profiler\windows\exp001-profile.ps1 prepare-tool -AllowDownload
```

## Static Verification

Profiler binary, Docker, DB 없이 lock/config/Docker policy/jq fixture/official result guard를 확인한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\tests\run-profiler-fixtures.ps1
```

```bash
bash scripts/exp-001/tests/run-profiler-fixtures.sh
```

Harness static guard만 확인하려면 다음 action을 사용한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\profiler\windows\exp001-profile.ps1 verify
```

## Docker Runtime

Compose runtime은 `scripts/exp-001/profiler/docker/`에 있다.

- Level 0: `compose.yml`
- Level 1: `compose.yml` + `compose.seccomp.yml`
- Level 2: `compose.yml` + `compose.sys-admin.yml`

금지 항목:

- `privileged: true`
- host PID namespace
- Docker socket mount
- fixed `container_name`
- 기본 capability로 `SYS_PTRACE` 추가

Level 0부터 smoke를 시도하고, 실패 stderr가 남을 때만 Level 1, Level 2로 올린다.

## Smoke

Smoke는 actual EXP-001 endpoint 50,000건 호출을 수행하지 않는다. 같은 app container PID namespace 안에서 `cpu`, `ctimer`, `alloc` attach와 tiny JFR conversion만 확인한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\profiler\windows\exp001-profile.ps1 smoke -SecurityLevel 0
```

Smoke가 성공하면 `scripts/exp-001/profiler/.state/smoke-ready.json`에 source revision, harness revision, profiler version, profiler asset SHA, security level, runtime, architecture, JDK identity, `selectedCpuEngine`을 기록한다. Profile action은 이 marker가 현재 값과 exact match일 때만 실행하고, CPU chunk에는 marker의 `selectedCpuEngine`을 그대로 사용한다.

## Actual Profile

Actual profile은 smoke 이후 별도 evidence 단계에서만 실행한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\profiler\windows\exp001-profile.ps1 profile -SecurityLevel 0 -AllowActualProfile
```

Profile order:

1. CPU JPA
2. CPU JDBC
3. allocation JDBC
4. allocation JPA

Warm-up은 profiler OFF 상태로 수행한다. 각 invocation 전 DB reset과 empty gate는 profiler window 밖에서 수행한다.

## Publication

Raw output:

```text
artifacts/exp-001/profiling/<profile-run-id>/
```

Tracked publication:

```text
results/exp-001/profiling/<profile-run-id>/
  metadata.md
  summary.json
  analysis.md
  manifest.md
```

Aggregation은 chunk manifest를 입력으로 사용해 sequence, filename, event, strategy, counter kind, workload gate, rows, source SHA를 먼저 검증한 뒤 collapsed stack counter를 합산한다. `summary.json` validator는 exact schema와 recursive sensitive key/value rejection을 적용한다.

`manifest.md`에는 raw artifact filename, size, SHA-256, event, strategy, chunk count만 기록한다. username, hostname, PID, absolute path는 기록하지 않는다.
