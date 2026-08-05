# Agent Instructions

This repository is a public Spring Boot persistence benchmark lab.

## 문서 및 응답 언어

- 사용자에게 제공하는 설명, 작업 계획, 질문, 경고, 검증 결과와 완료 보고는 한국어로 작성한다.
- 저장소의 사용자 대상 Markdown 문서는 기본적으로 한국어로 작성한다.
- 영어 요구사항이나 계획을 전달받더라도 자연어 설명은 한국어로 작성한다.
- 코드, 클래스명, 메서드명, package, 파일명, 경로, 명령어, 환경 변수, 설정 키와 기술 식별자는 원문을 유지한다.
- 라이브러리와 프레임워크의 공식 명칭은 번역하지 않는다.
- SQL, JSON, CSV, YAML의 필드명과 스키마 이름은 원문을 유지한다.
- 코드 블록과 명령어를 한국어로 번역하거나 변경하지 않는다.
- 로그와 오류 메시지를 인용할 때는 원문을 유지하고 필요한 설명만 한국어로 덧붙인다.
- Git branch 이름과 Conventional Commit의 type/scope는 영어를 사용한다.
- commit subject와 body, PR 제목과 본문의 자연어 설명은 한국어를 사용한다.
- 표준 오픈소스 License 본문은 공식 영문을 유지하며 임의로 번역하거나 수정하지 않는다.
- `LICENSE` 파일은 사용자 승인 없이 변경하지 않는다.

## 저장소 목적

- 이 저장소의 기본 운영 방향은 작은 백엔드 질문을 빠르게 실험하고 결과와 해석을 누적하는 학습 저장소이다.
- 이 저장소는 Spring Boot와 PostgreSQL 환경에서 Persistence 저장 경로의 정합성과 성능을 검증한다.
- JPA `saveAll`과 Spring JDBC Batch의 저장 동작, 데이터 정합성, 처리 시간, 처리량 및 성능 차이를 재현 가능한 방식으로 비교한다.
- profiler와 자동화는 백엔드 질문에 답하기 위한 보조 수단으로만 사용한다.
- 공식 benchmark 결과와 보조 profiler 결과는 분리해서 관리한다.
- 재현 가능성과 사람 검증 가능성을 자동화 편의보다 우선한다.
- 실행하지 않은 결과를 `PASS`로 표현하지 않는다.
- 확인하지 못한 원인을 사실처럼 단정하지 않는다.

## Source of Truth

- `README.md`: 저장소 전체 상태와 진입점.
- `docs/experiment-protocol.md`: 공통 실험 절차.
- `docs/experiments/`: 실험별 목적, 프로토콜 및 결과 해석.
- `results/`: 공식 실행 결과.
- `scripts/`: 반복 실행 도구와 사용법.
- local ignored runtime artifact는 tracked canonical Evidence와 구분한다.
- 존재하지 않는 경로나 새 문서를 임의로 Source of Truth로 만들지 않는다.

## 구성요소 책임

- AGENTS: 무엇을 지켜야 하는가.
- Common Commands: 어떻게 실행하는가.
- Skill: 어떻게 판단하는가.
- Hook: 어떤 위험 작업을 강제로 막는가.
- Issue: 이번 작업에서 무엇을 완료하는가.
- `AGENTS.md`에는 긴 PowerShell 명령, 특정 Issue 또는 PR 번호, 일회성 commit SHA, 특정 runtime artifact 경로를 넣지 않는다.

## Common Commands

### repo-preflight

- 목적: 작업 시작 시 local Git repository 위치와 현재 작업 상태를 사람과 AI가 같은 명령으로 확인한다.
- 전제: Git CLI가 설치되어 있고 Git work tree 내부에서 실행한다.
- 지원 환경: Git CLI를 실행할 수 있는 Windows PowerShell 5, Bash, macOS shell 및 그 밖의 shell.
- 명령:

```sh
git rev-parse --show-toplevel
git rev-parse HEAD
git --no-optional-locks status --short --branch
```

- 실행 순서: 위 세 명령을 작성된 순서대로 각각 실행한다.
- 출력: 각 Git 명령의 사람이 읽을 수 있는 원본 stdout과 stderr를 사용한다.
- 실행 결과: 각 명령의 native exit code를 별도로 기록한다.
- 성공: 세 명령이 모두 native exit code `0`이면 preflight 수집 완료로 기록한다.
- 실패: 한 명령이 non-zero이면 해당 명령에서 중단하고 실패한 명령, native exit code와 원본 stderr를 기록한다. 실행하지 않은 후속 명령은 `NOT_REACHED`로 기록하며 자동 retry하지 않는다.
- 상태 정보: dirty working tree, detached HEAD, upstream 미설정 및 ahead/behind 정보 미표시는 해당 Git 명령이 성공했다면 실패가 아니다.
- 동작 경계: `READ_ONLY`이며 repository를 변경하거나 network를 사용하지 않는다. status 명령은 `--no-optional-locks`를 사용해 optional index refresh/write를 방지하며, `fetch`, `pull` 및 remote API 호출을 수행하지 않는다.
- 원격 경계: upstream과 ahead/behind 정보는 표시되는 경우 local tracking ref 기준이며 remote 최신성을 보장하지 않는다.
- 보장하지 않는 것: output schema, automatic parsing, 별도 wrapper 및 통합 exit code.

## Git과 PR 경계

- 작업 전에 branch, `HEAD`, working tree와 index 상태를 확인한다.
- `main`은 직접 수정하지 않는다.
- 하나의 Issue는 하나의 독립 결과를 기본으로 한다.
- 하나의 PR은 해당 Issue 범위만 포함한다.
- unrelated 변경은 자동으로 복구하거나 삭제하지 않는다.
- force push, hard reset, branch 강제 삭제는 명시적 승인 없이 수행하지 않는다.
- push, PR 생성, merge는 각각 별도 승인 경계로 취급한다.
- 예상 head SHA가 있는 merge는 실행 직전에 head 이동 여부를 재확인한다.
- 파일 범위 또는 Git 상태가 예상과 다르면 중단한다.

## 실행 및 검증 상태

- `VERIFIED`: 실제 명령 또는 원본 Evidence로 확인됨.
- `PARTIAL`: 일부 조건만 확인됨.
- `UNVERIFIED`: 직접 확인하지 못함.
- `NOT_RUN`: 실행하지 않음.
- `NOT_REACHED`: 이전 단계 실패로 도달하지 못함.
- `NOT_CREATED`: 산출물이 생성되지 않음.
- `NOT_APPLIED`: 현재 범위에서 적용하지 않음.
- `BLOCKED`: 현재 Evidence와 승인 범위 안에서 완료할 수 없음.
- 사실 확인 수준과 명령 실행 결과를 구분한다.
- 예: `VERIFIED PASS`, `VERIFIED FAIL`, `PARTIAL`, `BLOCKED`.
- `NOT_RUN`, `NOT_REACHED`, `NOT_APPLIED`를 `PASS`로 표현하지 않는다.

## Evidence 원칙

- 실제 실행한 명령과 종료 결과를 기록한다.
- 실패 Evidence를 성공 Evidence로 덮어쓰지 않는다.
- 실행 결과, 해석, 추정을 분리한다.
- local ignored artifact를 canonical Evidence로 과장하지 않는다.
- 필요한 경우 branch, commit, run identity 및 해시를 기록한다.
- 같은 목적의 canonical Evidence는 기본적으로 하나만 둔다.
- 상태가 실제로 바뀐 경우에만 새 Evidence를 생성한다.
- secret, credential, 불필요한 절대 경로를 공개 문서에 기록하지 않는다.
- 존재하지 않는 파일이나 다른 clone에서 보장되지 않는 경로를 공개 Evidence 링크로 사용하지 않는다.

## 리뷰 분류

- `BLOCKING`: 공식 결론, 정합성, 보안, 문서 사실성, 필수 완료 조건 또는 merge 안전성을 무효화함.
- `REQUIRED_SUPPORT`: 현재 결과를 유지하기 위해 필요한 보조 수정.
- `NON_BLOCKING`: 현재 결과를 무효화하지 않는 개선 또는 후속 작업.
- `OUT_OF_SCOPE`: 현재 Issue와 독립적인 작업.
- 리뷰 severity와 `BLOCKING` 여부는 자동으로 같지 않다.
- unresolved thread라는 이유만으로 자동 `BLOCKING`으로 판정하지 않고, 현재 Issue의 완료 조건과 사실성을 실제로 무효화하는지 판단한다.

## 실패 보존과 재시도

- 실패 원인을 추측으로 수정하지 않는다.
- 실패 단계, 종료 코드, 생성 또는 미생성 산출물을 기록한다.
- cleanup 결과는 실행 결과와 별도로 확인한다.
- 직접 원인을 확정할 수 없으면 `UNVERIFIED` 또는 `BLOCKED`로 기록한다.
- 실패 후 자동 retry를 수행하지 않는다.
- 권한, 보안 수준, 실행 범위 상승은 새로운 승인이 필요하다.
- retry는 이전 자동 재시도의 연장이 아니라 원인 확인 후 별도 승인된 새 작업으로만 수행한다.
- 실패 산출물을 삭제하거나 성공 결과로 대체하지 않는다.

## Scope Stop

- 같은 지원 도구 수정은 최대 2회로 제한한다.
- 같은 문제의 리뷰 사이클은 최대 2회로 제한한다.
- 위 횟수 제한에 도달하면 현재 Issue의 작업을 중단하고 사람 검토를 받는다. 계속 작업이 필요하면 같은 Issue에서 완료 조건을 자동으로 확장하지 않고, 명시적으로 별도 승인된 새 Issue로 분리한다.
- 관련 상태가 바뀌지 않았다면 이미 통과한 검증을 반복하지 않는다.
- validator를 검증하기 위한 새 validator를 만들지 않는다.
- 지원 코드나 fixture가 핵심 실험보다 커지면 중단한다.
- 완료 조건이 작업 도중 증가하면 새 Issue로 분리한다.
- 직접 Evidence 없이 `PASS` 판정을 요구하면 중단한다.
- 하나의 Issue가 둘 이상의 독립 결과를 포함하면 분리한다.
- 공용 runner, fixture, schema, validator 또는 profiler harness 변경이 실험 질문 자체보다 커지면 중단하고 범위를 재검토한다.
- 원인 분석보다 지원 도구 확장이 커지면 `BLOCKED`를 검토한다.
- 문서 또는 Evidence 수가 증가해도 검증 가능성이 좋아지지 않으면 추가 생성을 중단한다.

## 작업 완료 흐름

- Issue에서 목적과 완료 조건을 확인한다.
- 작업 범위와 Non-goal을 확인한다.
- 승인된 범위 안에서 제한적으로 구현한다.
- 실제 검증 명령을 실행한다.
- 결과와 미실행 항목을 상태와 함께 기록한다.
- 사람 검토를 거친다.
- PR 검토를 거친다.
- merge 후 Issue를 종료한다.
- 세부 Git 명령과 긴 실행 절차는 `AGENTS.md`가 아니라 Common Commands 또는 해당 Issue가 소유한다.

## 실험 코드의 목적과 종속성 원칙

### 1. 실험 질문 우선

- 작업을 시작할 때 답하려는 백엔드 질문을 한 문장으로 두고, 성능 테스트나 기술 검증 전에는 그 질문을 먼저 명확히 정의한다.
- 모든 코드와 도구는 해당 질문에 직접 필요한지 검토한다.
- 실험 질문과 직접 관계없는 기능은 애플리케이션 소스에 추가하지 않는 것을 기본 원칙으로 한다.

### 2. 애플리케이션과 실험 하네스의 책임 분리

- 애플리케이션 소스에는 측정 대상 동작을 호출하기 위한 최소한의 진입점과 결과만 둔다.
- 애플리케이션에는 profiling 전용 profile 또는 source set, 측정 대상 호출 진입점, deterministic input 생성, 기존 service 호출, 측정에 필요한 최소 결과 반환, 정합성 확인에 필요한 최소 조회 기능만 둔다.
- 애플리케이션 시작과 종료, 환경 점검, DB 초기화, warm-up, 반복 실행, 동시 부하 생성, timeout 관리, profiler 실행, 결과 수집과 집계는 기본적으로 외부 실험 하네스가 담당한다.
- 외부 실험 하네스에는 Shell 또는 PowerShell script, k6, async-profiler, curl, psql, jq, awk 등 검증 목적에 맞는 표준 도구를 우선 사용한다.

### 3. 테스트 보조 기술의 소스 종속 금지

- 테스트 보조 기술은 가능한 한 애플리케이션 밖에서 사용한다.
- 실험 전용 framework, 범용 registry, 불필요한 interface와 adapter, Git 또는 Docker 제어 코드, 범용 writer, 프로세스 제어 framework, 결과 lifecycle framework를 애플리케이션 소스에 연쇄적으로 추가하지 않는다.
- 테스트 보조 기술 때문에 기존 비즈니스 코드나 transaction 구조를 변경하지 않는다.

### 4. 로우레벨 구현의 허용 조건

- 표준 라이브러리와 공개된 상위 수준 추상화를 우선 사용한다.
- 로우레벨 구현은 학습 목적, 제품 요구사항, 측정 정확성, 데이터 정합성·안전성, 실험 변수 통제 또는 그 밖에 상위 추상화로 충족하기 어려운 명확한 기술적 필요가 있을 때만 허용한다. 해당 필요와 적용 범위는 Issue에 기록한다.
- 단순한 선호, 불필요한 최적화, 과설계 또는 구현 가능성만을 로우레벨 구현 근거로 사용하지 않는다.

### 5. 복잡성 경고 기준

- 실험 지원 코드가 측정 대상 코드보다 많아지면 과설계를 의심한다.
- 기술 하나를 테스트하기 위해 여러 계층의 추상화가 필요해지면 중단하고 경계를 다시 검토한다.
- 단 한 번의 실험을 위해 범용 framework를 만들지 않는다.
- 외부 명령 한두 개로 가능한 일을 Java로 다시 구현하지 않는다.
- 테스트를 제거해도 실험 지원 코드만 대량으로 남는 구조를 만들지 않는다.
- 애플리케이션이 Git, Docker, profiler와 결과 파일 형식을 직접 관리하지 않는다.
- 외부 도구로 충분한 경우 애플리케이션 내부 framework 구현보다 script-first, external-tool-first 방식을 우선한다.

## 공개 작업 경계

- 공개 저장소의 source file만 사용한다.
- private repositories, private artifacts, previous private session context에 접근하지 않는다.
- schema ownership은 Flyway migrations에 둔다.
- Hibernate는 `ddl-auto: validate`를 유지한다.
- `M0` 범위에서는 Controller 또는 benchmark HTTP endpoint를 추가하지 않는다.
- 후속 실험에서 실행 하네스용 endpoint가 필요하면 해당 Issue와 실험 프로토콜에 목적과 경계를 명시하고 별도 승인을 받은 경우에만 추가한다.
- 명시 승인 없이 새 성능 실험, profiler smoke, 공식 benchmark를 실행하거나 공식 결과로 기록하지 않는다.
- JFR, publication 또는 공용 profiler harness 확장은 명확한 필요와 별도 사람 승인이 있을 때만 진행한다.
- license 선택 전에는 `LICENSE` 파일을 생성하지 않는다.
- 명시 승인 없이 commit, push, remote 추가, GitHub repository 생성, PR 생성 또는 merge를 수행하지 않는다.
- `.idea/` 파일은 stage하지 않는다.
