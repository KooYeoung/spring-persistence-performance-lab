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

## 실험 코드의 목적과 종속성 원칙

### 1. 실험 질문 우선

성능 테스트나 기술 검증을 시작하기 전에 검증하려는 질문을 한 문장으로 명확히 정의한다.

모든 코드와 도구는 해당 질문에 직접 필요한지 검토한다.

실험 질문과 직접 관계없는 기능은 애플리케이션 소스에 추가하지 않는 것을 기본 원칙으로 한다.

### 2. 애플리케이션과 실험 하네스의 책임 분리

애플리케이션 소스에는 측정 대상 동작을 호출하기 위한 최소한의 진입점과 결과만 둔다.

다음 책임은 기본적으로 외부 실험 하네스에서 처리한다.

- 애플리케이션 시작과 종료
- 환경 점검
- DB 초기화
- warm-up
- 반복 실행
- 동시 부하 생성
- timeout 관리
- async-profiler 실행
- CPU, wall, allocation profile 수집
- 결과 파일 저장
- 중앙값과 통계 계산
- 결과 요약 문서 생성

외부 실험 하네스에는 상황에 따라 다음 도구를 사용한다.

- Shell 또는 PowerShell script
- k6
- async-profiler
- curl
- psql
- jq
- awk
- 기타 검증 목적에 적합한 표준 도구

### 3. 테스트 보조 기술의 소스 종속 금지

테스트에 사용하는 하나의 기술 때문에 운영 또는 핵심 애플리케이션 소스에 다음이 연쇄적으로 추가된다면 설계를 중단하고 경계를 다시 검토한다.

- 실험 전용 framework
- 범용 registry
- 불필요한 interface와 adapter
- Git 또는 Docker 제어 코드
- 범용 CSV, JSON, Markdown writer
- 프로세스 제어 framework
- 실험 결과 lifecycle framework
- 현재 요구되지 않은 확장용 추상화

테스트 보조 기술은 가능한 한 애플리케이션 밖에서 사용한다.

### 4. 로우레벨 구현의 허용 조건

다음 중 하나에 해당할 때만 로우레벨 구현을 허용한다.

- 해당 로우레벨 기술 자체가 학습 대상이다.
- 제품의 실제 요구사항이다.
- 외부 도구로 해결할 수 없다.
- 측정 정확성이나 데이터 안전성을 위해 반드시 필요하다.
- 기존 표준 도구보다 직접 구현이 명확하게 단순하다.

단순히 구현할 수 있다는 이유로 직접 구현하지 않는다.

### 5. 최소 측정 경계

애플리케이션에는 가능한 한 다음만 둔다.

- profiling 전용 profile 또는 source set
- 측정 대상 호출 진입점
- deterministic input 생성
- 기존 service 호출
- 측정에 필요한 최소 결과 반환
- 정합성 확인에 필요한 최소 조회 기능

다음은 외부 스크립트가 담당한다.

- 호출 순서
- 반복 횟수
- DB reset
- cooldown
- concurrency
- profiler 연결
- 결과 수집과 집계

### 6. 복잡성 경고 기준

다음 중 하나에 해당하면 과설계를 의심한다.

- 실험 지원 코드가 측정 대상 코드보다 많다.
- 기술 하나를 테스트하기 위해 여러 계층의 추상화가 추가된다.
- 단 한 번의 실험을 위해 범용 framework를 만든다.
- 외부 명령 한두 개로 가능한 일을 Java로 다시 구현한다.
- 테스트를 제거해도 실험 지원 코드만 대량으로 남는다.
- 애플리케이션이 Git, Docker, profiler와 결과 파일 형식을 직접 관리한다.
- 실험 도구 때문에 기존 비즈니스 코드나 transaction 구조가 변경된다.

이 경우 AI는 구현을 계속하기 전에 script-first, external-tool-first 대안을 우선 제시해야 한다.

### 7. 학습 목적 예외

로우레벨 구현 자체가 학습 목적이라면 일반적인 최소 구현 원칙보다 학습 범위를 우선할 수 있다.

단, 문서에 다음을 명시한다.

- 학습하려는 기술
- 직접 구현하는 이유
- 실제 프로젝트에서는 사용할 표준 도구
- 학습용 코드와 운영 코드의 경계

학습 목적이 아니라면 불필요한 로우레벨 구현을 추가하지 않는다.

### 8. AI의 과설계 방지 의무

AI는 사용자의 요청을 구현하기 전에 다음을 확인한다.

1. 이것은 제품 코드인가, 실험 진입점인가, 외부 실험 하네스인가?
2. 이 코드가 실험 질문에 직접 필요한가?
3. 표준 도구나 스크립트로 더 단순하게 해결할 수 있는가?
4. 테스트 기술이 애플리케이션 구조를 침범하고 있지 않은가?
5. 확장 가능성만을 이유로 현재 필요 없는 추상화를 만들고 있지 않은가?

외부 도구로 충분한 경우 AI는 애플리케이션 내부 framework 구현보다 script-first 방식을 우선 제안한다.

Rules for M0 work:

- Use only the public source files in this repository.
- Do not access private repositories, private artifacts, or previous private session context.
- Keep schema ownership in Flyway migrations.
- Keep Hibernate set to `ddl-auto: validate`.
- Do not add a controller or benchmark HTTP endpoint for M0.
- Do not run EXP-001 or record official 50,000-row performance results in M0.
- Do not create a `LICENSE` file until the license choice is made.
- Do not commit, push, add a remote, or create a GitHub repository without explicit user approval.
- Do not stage `.idea/` files.
