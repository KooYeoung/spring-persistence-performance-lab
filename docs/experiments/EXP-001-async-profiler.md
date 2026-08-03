# EXP-001 Async-profiler Phase B Protocol

상태: Level 0 smoke `VERIFIED`, Actual profile `NOT_APPLIED`, publication `NOT_CREATED`.

이 문서는 EXP-001 Phase B async-profiler evidence protocol이다. Phase A official timing result는 `docs/experiments/EXP-001-jpa-saveall-vs-jdbc-batch.md`가 계속 소유한다.

## 실험 질문

동일한 공개 구현에서 50,000건 저장을 수행할 때 JPA `saveAll` 경로와 JDBC batch 경로의 elapsed time 차이는 CPU sample과 sampled allocation 관점에서 어떤 원인 후보를 보이는가?

Phase B는 원인 분석 evidence이며 official elapsed comparison을 대체하지 않는다.

## Phase A와 Phase B 분리

Phase A official result:

- path: `results/exp-001/20260727T053643Z-2d76b26`
- 성격: timing + consistency official public reproduction result
- profiler: 사용하지 않음
- 변경 정책: immutable legacy artifact

Phase B profiler evidence:

- path: `results/exp-001/profiling/<profile-run-id>/`
- 성격: CPU/allocation 원인 후보 분석
- profiler: async-profiler
- raw artifact: `artifacts/exp-001/profiling/<profile-run-id>/`
- tracked artifact: sanitized allowlist 4개

Phase B 결과는 Phase A elapsed result의 대표값으로 사용하지 않는다.

## 현재 실행 결과

### Post-fix Level 0 smoke

- Issue: #29
- 실행 branch: `main`
- 실행 commit: `4cca0ee2dc57e1945dc9f170c1092cdc3bae6afb`
- smoke run id: `smoke-20260803T040521Z`
- execution UTC: `2026-08-03T04:05:19Z` ~ `2026-08-03T04:05:46Z`
- canonical command execution count: `1`
- native exit code: `0`
- async-profiler: `4.5`
- markerFormatVersion: `2`
- smokeSuccess: `true`
- marker sourceRevision: `4cca0ee2dc57e1945dc9f170c1092cdc3bae6afb`
- marker harnessRevision: `2bfe1621f8c34e6746a8c0f59299ce4854345d72152cd278a67bd44ee53cb261`
- selectedCpuEngine: `ctimer`
- engineVerification: `jfr-active-setting-engine:ctimer`

CPU 요청 세션의 실제 engine은 JFR `jdk.ActiveSetting`에서 `ctimer`로 검증되었다. 산출물명이 `cpu.jfr`와 `cpu.cpu.collapsed`이고 `selectedCpuEngine=ctimer`인 것은 smoke runner 계약상 허용되는 결과이다.

- Level 0 smoke attempted: `true`
- attempts: `1`
- retry: `NOT_APPLIED`
- readiness: `VERIFIED`, `PASS`
- require-tool: `VERIFIED`, `PASS`
- CPU profiler start: `VERIFIED`, `PASS`
- CPU workload: `VERIFIED`, `PASS`
- target JVM identity gate: `VERIFIED`, `PASS`
- CPU stop/JFR: `VERIFIED`, `PASS`
- CPU collapsed conversion: `VERIFIED`, `PASS`
- CPU sample count: `315`
- allocation profiler start: `VERIFIED`, `PASS`
- allocation workload: `VERIFIED`, `PASS`
- allocation stop/JFR: `VERIFIED`, `PASS`
- allocation collapsed conversion: `VERIFIED`, `PASS`
- allocation sample count: `60`
- allocation sampled bytes: `62391216`
- cleanup: `VERIFIED PASS`
- marker v2: `VERIFIED`, `PASS`
- actual profile: `NOT_APPLIED`
- publication: `NOT_CREATED`

Final JFR와 collapsed output은 모두 non-empty였다. profiler stop은 성공 경로였고 non-empty temporary JFR 확인 후 final JFR로 승격되었다. stdout/stderr capture 크기는 `6652 / 5348` bytes였으며, stderr는 Compose lifecycle, readiness poll, `JAVA_TOOL_OPTIONS` 출력으로 분류하고 command failure로 보지 않는다. stdout/stderr의 local absolute path와 사용자명은 공개 문서에 기록하지 않는다.

위 결과는 post-fix Level 0 smoke의 상태이며 Phase A official benchmark를 무효화하지 않는다. Phase B actual profile과 tracked publication은 아직 생성하지 않았다.

### Historical pre-fix Level 0 smoke

- 실행 branch: `exp/exp-001-profiler-smoke`
- 실행 commit: `647d10bb0ec4f868c32a2aca3b652f244e602101`
- branch 성격: `local historical runtime branch`
- main 반영: `NOT_APPLIED`
- push/PR/merge: `NOT_APPLIED`
- CPU stop/JFR: `BLOCKED`
- allocation: `NOT_REACHED`
- marker v2: `NOT_CREATED`
- cleanup: `VERIFIED PASS`

이 historical smoke 결과는 Issue #27 수정 전 local runtime branch에서 확인한 결과이며, post-fix Level 0 smoke 결과로 대체해서 성공 Evidence로 해석하지 않는다.

## Diagnostic

- local ignored artifact: `artifacts/exp-001/profiling/smoke-20260731T131941Z/raw/smoke/cpu.asprof-stop-diagnostic.json`
- SHA-256: `952F5C5B4F6E1F2600B963388452779BEB3731C73E099A901BA67F6EB401B1E9`
- reason: `jfr-temp-missing`
- rawExit: `0`
- stdout/stderr: `0 bytes / 0 bytes`
- temp/final JFR: 생성되지 않음
- root cause: `UNVERIFIED`
- classification: `CPU_STOP_JFR_ROOT_CAUSE_UNRESOLVED`

위 diagnostic은 local ignored runtime artifact이다. Git에 포함된 canonical Evidence가 아니며 다른 clone에서 해당 path의 존재를 보장하지 않는다. 보존된 정보만으로 permission, seccomp, perf 또는 PID 문제라고 추측하지 않는다.

## Static Root Cause And Fix State

- primary harness defect: `VERIFIED_BY_STATIC_EVIDENCE`
- sole runtime cause: `NOT_CLAIMED`
- harness fix: `IMPLEMENTED`
- post-fix runtime validation: `VERIFIED`
- JFR session fix effectiveness: `VERIFIED_FOR_LEVEL0_SMOKE`
- Level 0 smoke: `VERIFIED`
- actual profile: `NOT_APPLIED`
- publication: `NOT_CREATED`

정적 진단에서 확인한 primary harness defect는 Issue #27 수정 전 harness가 `asprof start` 시점에 `-o jfr -f <temporary-jfr>`를 지정하지 않고, `asprof stop` 시점에만 JFR output을 요청한 session configuration mismatch이다.

Issue #27 수정 후 harness는 final JFR 경로와 temporary JFR 경로를 `asprof start` 전에 결정하고, CPU/ctimer/alloc start 명령에 `-o jfr -f <temporary-jfr>`를 지정한다. 정상 stop은 output을 다시 지정하지 않고 동일 session을 종료하며, stop 성공과 non-empty temporary JFR를 확인한 뒤에만 final JFR로 승격한다.

Issue #29 post-fix Level 0 smoke에서 이 수정은 실제 Docker container와 async-profiler 4.5 실행 환경 기준으로 검증되었다. 이 검증은 Level 0 smoke 범위에 한정하며, actual profile 및 publication은 별도 Human Gate 전까지 `NOT_APPLIED` 또는 `NOT_CREATED` 상태를 유지한다.

## Fixture validation

Historical smoke limitation:

- independent fixture revalidation: `PARTIAL`
- Windows working-tree CRLF 문제가 확인되었다.
- local LF 변환 후 Bash syntax는 `PASS`였다.
- portable `jq` 부재로 full fixture suite는 완료되지 않았다.
- fixture suite가 `PASS`하지 않은 상태에서 smoke가 실행되었다.

Issue #27 static fixture validation:

- shell syntax validation: `VERIFIED`, `PASS`
- PowerShell fixture validation: `VERIFIED`, `PASS`
- Bash profiler fixture validation: `PARTIAL`
- Bash profiler fixture observation: PATH의 `bash`는 sourced `scripts/exp-001/macos/common.sh` CRLF에서 중단되었다. Git Bash는 `EXP-001 profiler fixture tests passed.` marker를 출력했지만 native exit code `0`으로 종료되지 않고 command timeout이 발생했으므로 `VERIFIED PASS`로 승격하지 않는다.

이 제한은 `PASS`로 승격하지 않는다.

## Scope closure

- scopeFrozen: `true`
- additionalHarnessChangesAllowed: `false`
- Level 1/2: `NOT_RUN`
- retry: `NOT_APPLIED`
- actual profile: `NOT_APPLIED`
- publication: `NOT_CREATED`
- final profiler result: `NOT_CREATED`

## Tool Pin

async-profiler는 `scripts/exp-001/tools/async-profiler.lock`로 고정한다.

| 항목 | 값 |
|---|---|
| version | `4.5` |
| tag | `v4.5` |
| platform | `linux-x64` |
| asset | `async-profiler-4.5-linux-x64.tar.gz` |
| SHA-256 | `89546fbb9ee0fc5496c7edd4099b0709489bc78b0d8057ccbb4b801f6b032b62` |
| license | `Apache-2.0` |

Binary, archive, extracted tool directory는 Git에 포함하지 않는다.

## Runtime

Native Windows runtime은 지원하지 않는다. Windows JVM에 Linux 또는 macOS async-profiler를 attach하지 않는다.

Primary runtime:

- Docker Desktop Linux x64 container
- application JVM과 `asprof`는 같은 app container PID namespace에서 실행
- PostgreSQL은 별도 Compose service
- JVM user와 profiler user는 같은 non-root `app` user

Docker security escalation은 Level 0부터 시작한다.

| Level | Compose | 추가 권한 |
|---:|---|---|
| 0 | `compose.yml` | 없음 |
| 1 | `compose.yml`, `compose.seccomp.yml` | `seccomp=unconfined` |
| 2 | `compose.yml`, `compose.sys-admin.yml` | `seccomp=unconfined`, `SYS_ADMIN` |

`privileged: true`, host PID namespace, Docker socket mount, fixed `container_name`은 금지한다. `SYS_PTRACE`는 공식 근거와 attach 실패 stderr가 확인될 때만 별도 후보로 기록하고 기본값으로 추가하지 않는다.

## Smoke Gate

Actual 50,000-row profile 전에 smoke를 통과해야 한다.

Smoke workload는 DB를 사용하지 않는 `exp001` 전용 endpoint 호출과 tiny output conversion이다. EXP-001 저장 endpoint 50,000건 호출은 수행하지 않는다.

Smoke endpoint:

- readiness: `GET /internal/exp-001/smoke/ready`
- CPU workload: `POST /internal/exp-001/smoke/cpu`
- allocation workload: `POST /internal/exp-001/smoke/allocation`

Readiness response는 HTTP `200`에서 exact JSON object `{ "status": "READY", "phase": "EXP001_SMOKE" }`만 허용한다. Smoke workload response는 structural JSON gate로 whole input consumption, exact key set, duplicate/unknown/missing key rejection, type checking, integer policy, checksum, body size `4096` bytes 이하를 검증한다. Malformed JSON, trailing garbage, string `"true"`, numeric string, decimal/exponent/negative/overflow integer, HTTP `409`/`500`은 fail-closed로 실패한다.

Active profiler session이 시작된 뒤 workload gate failure 또는 JVM identity mismatch가 발생해도 harness는 profiler stop을 best-effort로 수행한 뒤 실패를 반환한다. Stop failure는 원래 오류와 함께 보고하며 event 성공으로 처리하지 않는다. JFR conversion과 sample threshold validation은 stop 성공 후에만 수행한다.

CPU actual engine은 `jfr print --json --events jdk.ActiveSetting` 출력의 `jdk.ActiveSetting` event에서 `values.name=engine`인 `values.value`만 읽는다. Accepted actual engine은 `perf_events`, `ctimer`이고 unrelated object의 `engine` field와 stack/class 문자열은 무시한다. `engineVerification`은 `jfr-active-setting-engine:perf_events` 또는 `jfr-active-setting-engine:ctimer`만 허용한다. Parser 실패, conflicting/missing/unknown engine, sample hard threshold 미달, cleanup 실패 시 marker는 생성하지 않는다.

Smoke 확인 항목:

- Docker image build
- Linux JDK runtime
- `asprof --version`
- target JVM identity
- `cpu` attach start/stop
- `ctimer` fallback viability
- `alloc` attach start/stop
- tiny JFR output
- `jfrconv` collapsed conversion
- artifact volume write
- cleanup

Smoke가 실패하면 actual profile execution을 금지한다. 성공 marker는 `markerFormatVersion=2` exact schema로 source revision, harness revision, profiler version, profiler asset SHA, security level, runtime, architecture, JDK identity, `selectedCpuEngine`, smoke/workload protocol version, sample count, sampled bytes, engine verification을 기록한다. Profile action은 현재 값과 marker가 모두 일치할 때만 실행하며 CPU chunk는 marker의 `selectedCpuEngine`을 사용한다.

`selectedCpuEngine=cpu`는 CPU smoke JFR의 actual engine이 `perf_events`로 확인될 때만 허용한다. `cpu` start가 실패하거나 actual engine이 `ctimer`이면 marker에는 `selectedCpuEngine=ctimer`를 기록하고, 이후 CPU chunk는 explicit `ctimer` event를 사용한다. JFR actual engine을 정확히 하나 추출하지 못하면 `ENGINE_DETECTION_UNRESOLVED`로 실패한다.

## Recording Model

Recording unit은 per-invocation chunk이다. DB reset과 empty gate는 profiler window 밖에서 수행한다.

CPU:

- preferred event: `cpu`
- fallback event: `ctimer`
- interval: `10ms`
- JPA chunks: `1`
- JDBC chunks: `25`

Allocation:

- event: `alloc`
- interval: `--alloc 512k`
- JPA chunks: `1`
- JDBC chunks: `5`

Rows per invocation은 `50,000`으로 고정한다.

Warm-up은 profiler OFF 상태로 수행한다.

- JPA warm-up: `1`
- JDBC warm-up: `5`

Profile order:

1. CPU JPA
2. CPU JDBC
3. allocation JDBC
4. allocation JPA

이 순서는 official latency comparison protocol이 아니므로 Phase A의 6-round alternating protocol을 복제하지 않는다. JIT/cache 편향 가능성은 metadata와 analysis에 기록한다.

## Conversion And Aggregation

Source JFR은 full profile로 raw artifact에 보존한다. Derived view는 full profile과 target-method-filtered profile을 모두 만든다.

Collapsed 변환:

- CPU: `jfrconv --cpu --dot --norm -o collapsed`
- allocation samples: `jfrconv --alloc --dot --norm -o collapsed`
- allocation bytes: `jfrconv --alloc --total --dot --norm -o collapsed`

Aggregation은 chunk manifest를 입력으로 사용한다. Manifest는 expected chunk count, 1부터 N까지 연속 sequence, duplicate filename, event/strategy/counter kind mismatch, workload gate, rows, source SHA를 검증한 뒤 stack key별 counter를 합산한다.

Target filters:

- JPA: `com\.example\.persistencebenchmark\.persistence\.jpa\.JpaBenchmarkRecordPersistenceService\.saveAll`
- JDBC: `com\.example\.persistencebenchmark\.persistence\.jdbc\.JdbcBatchBenchmarkRecordPersistenceService\.saveAll`

Filtered share는 전체 profile의 절대 비율로 해석하지 않는다. `analysis.md`에는 full profile과 target-method-filtered view의 경계를 명시한다.

## Thresholds

Smoke CPU sample count:

- recommended: `>= 100`
- hard minimum: `< 50`이면 fail

Smoke allocation sample count:

- recommended: `>= 16`
- hard minimum: `< 8`이면 fail

Smoke allocation sampled bytes:

- recommended: `>= 8MiB`
- hard minimum: `< 4MiB`이면 fail

CPU sample count:

- recommended: `>= 1000`
- hard minimum: `< 300`이면 fail

Allocation sample count:

- recommended: `>= 200`
- hard minimum: `< 100`이면 fail

Sample 부족, missing/duplicate chunk, event mismatch, strategy mismatch, CPU engine mismatch, invalid workload gate는 전체 profile run 실패로 처리한다. 부분 보충 없이 새 run ID로 재실행한다.

CPU `cpu`와 `ctimer` profile은 같은 comparison table에 섞지 않는다. JPA와 JDBC CPU profile의 actual engine이 같을 때만 같은 profile set으로 채택한다.

## Publication

Raw artifact path:

```text
artifacts/exp-001/profiling/<profile-run-id>/
```

Tracked publication path:

```text
results/exp-001/profiling/<profile-run-id>/
  metadata.md
  summary.json
  analysis.md
  manifest.md
```

Tracked allowlist 밖 파일은 commit하지 않는다.

금지 파일:

- `.jfr`
- `.html`
- `.collapsed`
- raw response
- profiler stderr/log
- heap dump
- DB dump
- binary/archive
- temp/partial file

`summary.json` validator는 exact allowed-key schema와 recursive sensitive key/value rejection을 적용한다. `manifest.md`에는 raw artifact filename, size, SHA-256, event, strategy, chunk count만 기록한다. username, hostname, PID, absolute path, private identifier는 기록하지 않는다.

## Summary Schema

`summary.json` top-level:

- `profileFormatVersion`
- `experiment`
- `phase`
- `profileRunId`
- `sourceRevision`
- `harnessRevision`
- `runtime`
- `profiler`
- `profiles`
- `crossProfileValidation`
- `success`

Profile entry:

- `event`
- `cpuEngine`
- `strategy`
- `interval`
- `repetitions`
- `totalRows`
- `chunkCount`
- `validChunkCount`
- `sampleCount`
- `sampledValue`
- `normalizationUnit`
- `topPackages`
- `topClasses`
- `topMethods`
- `topStacks`
- `workloadGate`
- `artifactManifest`
- `sampleThreshold`
- `success`

CPU sample count는 exact CPU time으로 표현하지 않는다. Allocation entry는 sample count와 sampled bytes를 분리하고 50,000 rows 기준 normalized sampled value를 기록한다.

## Commands

Static fixture:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\tests\run-profiler-fixtures.ps1
```

Static harness guard:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\profiler\windows\exp001-profile.ps1 verify
```

Tool preparation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\profiler\windows\exp001-profile.ps1 prepare-tool -AllowDownload
```

Smoke:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\profiler\windows\exp001-profile.ps1 smoke -SecurityLevel 0
```

Cleanup:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\profiler\windows\exp001-profile.ps1 cleanup -SecurityLevel 0
```

Actual profile:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\profiler\windows\exp001-profile.ps1 profile -SecurityLevel 0 -AllowActualProfile
```

Actual profile은 smoke 통과, clean working tree, explicit `-AllowActualProfile`이 모두 충족될 때만 실행한다.

## Regression Guard

`scripts/exp-001/profiler/shared/official-result-manifest.json`는 기존 official result 16개 파일의 SHA-256과 file count를 검증한다.

Guard 실패 시 다음을 금지한다.

- profiler execution
- publication 확정
- stage
- commit
