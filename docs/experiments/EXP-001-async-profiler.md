# EXP-001 Async-profiler Phase B Protocol

상태: harness 구현 단계. Actual profiler execution과 evidence publication은 smoke 통과 후 별도 단계에서 수행한다.

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

Smoke workload는 idle JVM attach와 tiny output conversion이다. EXP-001 endpoint 50,000건 호출은 수행하지 않는다.

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

Smoke가 실패하면 actual profile execution을 금지한다. 성공 marker는 source revision, harness revision, profiler version, profiler asset SHA, security level, runtime, architecture, JDK identity, `selectedCpuEngine`을 exact schema로 기록한다. Profile action은 현재 값과 marker가 모두 일치할 때만 실행하며 CPU chunk는 marker의 `selectedCpuEngine`을 사용한다.

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
