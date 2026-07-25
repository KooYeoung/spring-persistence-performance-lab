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
