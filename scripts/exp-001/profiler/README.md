# EXP-001 Async-profiler Harness

이 harness는 EXP-001 Phase B evidence 수집용이다.

실험 질문: 동일한 공개 구현에서 50,000건 저장을 수행할 때 JPA `saveAll` 경로와 JDBC batch 경로의 elapsed time 차이는 CPU sample과 sampled allocation 관점에서 어떤 원인 후보를 보이는가?

현재 상태: post-fix Level 0 smoke는 `VERIFIED`이고 Actual profile은 `NOT_APPLIED`이다. Publication은 `NOT_CREATED`이며 상세 결과는 `docs/experiments/EXP-001-async-profiler.md`를 참조한다.

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

## Smoke Protocol v2

Smoke는 `exp001` profile에서만 노출되는 DB-free endpoint를 사용한다.

- readiness: `GET /internal/exp-001/smoke/ready`
- CPU workload: `POST /internal/exp-001/smoke/cpu`
- allocation workload: `POST /internal/exp-001/smoke/allocation`

Readiness response는 HTTP `200`에서 JSON object의 exact key set이 `status`, `phase`이고 값은 각각 `READY`, `EXP001_SMOKE`일 때만 통과한다. CPU/allocation smoke response는 source-file Java JSON gate로 전체 JSON 문법, full input consumption, duplicate key, unknown field, missing key, wrong type, integer policy, checksum, body size `4096` bytes 이하를 구조적으로 검증한다. Malformed JSON, trailing garbage, string `"true"`, numeric string, decimal/exponent/negative/overflow integer, HTTP `409`/`500`은 fail-closed로 거부한다.

Active profiler session이 시작된 뒤 workload gate 실패나 JVM identity mismatch가 발생하면 harness는 원래 오류를 보존하고 profiler stop을 best-effort로 먼저 시도한다. Stop 실패는 별도 오류로 함께 보고하며 event 성공으로 처리하지 않는다. Stop이 성공한 뒤에만 JFR conversion과 sample threshold validation을 수행한다.

CPU engine은 `jfr print --json --events jdk.ActiveSetting` 결과의 `jdk.ActiveSetting` event에서 `values.name=engine`인 `values.value`만 읽는다. Accepted actual engine은 `perf_events`, `ctimer`이고, unrelated object의 `engine` field나 stack/class 문자열은 무시한다. `engineVerification` marker 값은 `jfr-active-setting-engine:perf_events` 또는 `jfr-active-setting-engine:ctimer`만 허용한다. Parser 실패, conflicting/missing/unknown engine, sample hard threshold 미달, cleanup 실패 시 marker 후보는 final marker로 승격하지 않는다.

CPU workload는 약 3초 동안 primitive `long` mixing loop를 실행하고, HTTP response에서 `success=true`, `workload=cpu`, `iterations>0`, `durationMillis>=2500`, lowercase hex `checksum`을 검증한다. Allocation workload는 endpoint 완료 전까지 `1MiB` byte array 64개를 local reference로 유지하며 총 `67108864` bytes, `chunkBytes=1048576`, `chunks=64`를 검증한다. 동시에 실행 중인 smoke workload가 있으면 애플리케이션은 HTTP `409`를 반환한다.

Container harness는 readiness 이후 JVM identity를 고정하고, profiler start 후 smoke endpoint를 호출한 뒤 identity를 재검증하고 stop/conversion을 수행한다. CPU collapsed counter 합계는 hard minimum `50`, allocation sample counter 합계는 `8`, allocation sampled-byte counter 합계는 `4MiB` 미만이면 실패한다. CPU engine은 `jfr print --json` 결과에서 `perf_events` 또는 `ctimer`를 정확히 하나 추출해야 하며, `selectedCpuEngine=cpu`는 actual engine이 `perf_events`로 확인될 때만 기록한다.

Smoke marker는 `markerFormatVersion=2` exact schema만 허용한다. 기존 revision/version/runtime 필드에 더해 `smokeProtocolVersion`, `cpuWorkloadVersion`, `allocationWorkloadVersion`, `cpuSampleCount`, `allocationSampleCount`, `allocationSampledBytes`, `engineVerification`을 기록한다. `smoke` action은 compose cleanup과 residual resource gate가 성공한 뒤에만 marker 후보를 final marker로 승격한다.

운영자가 중간 실패 후 resource를 정리해야 할 때는 다음 action을 사용한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\profiler\windows\exp001-profile.ps1 cleanup -SecurityLevel 0
```

`cleanup`은 `exp001-profiler` Compose project의 container/network/volume을 제거하고 `.tmp.*` partial artifact를 정리한다. Final smoke marker와 final raw artifact는 자동 삭제하지 않는다.

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
