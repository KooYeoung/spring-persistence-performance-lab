# spring-persistence-performance-lab

Spring Boot와 PostgreSQL에서 합성 데이터 기반 JPA `saveAll` 경로와 Spring JDBC batch 경로의 저장 동작 및 정합성을 검증하는 공개 실험 저장소.

M0 초기 범위는 정합성만 검증한다. EXP-001 Phase A official benchmark는 `results/exp-001/20260727T053643Z-2d76b26`에 공개되어 있으며, Phase B profiler smoke와 actual profile은 별도 상태로 관리한다.

## 기본 학습 흐름

이 저장소는 작은 백엔드 질문을 빠르게 실험하고 결과와 해석을 누적하는 학습 저장소를 기본 방향으로 한다.

기본 흐름: `질문 → 가설 → 작은 실험 → 정합성 확인 → profiler OFF 반복 측정 → 필요한 경우에만 병목 프로파일링 → 결과·한계·다음 질문 기록`

Profiler는 선택적인 보조 도구이며 모든 실험에 필수는 아니다. 성능 수치는 profiler OFF 상태의 반복 측정으로 작성하고, 기존 Phase A official benchmark와 Phase B Level 0 smoke 상태는 변경하지 않는다.

## 현재 실험 상태

- M0 정합성 검증: 합성 입력 저장 결과의 row count, key set, duplicate key, missing key, normalized snapshot, SHA-256 checksum을 검증한다.
- EXP-001 Phase A official benchmark: `VERIFIED`. official JSON 12개, warm-up JSON 2개, 총 16개 파일이 `results/exp-001/20260727T053643Z-2d76b26`에 있다.
- EXP-001 Phase B profiler smoke: `VERIFIED`. post-fix Level 0 smoke에서 non-empty JFR와 collapsed output 생성이 확인되었다.
- Actual profile: `NOT_APPLIED`. Publication은 `NOT_CREATED`이며 Phase B 상세 상태는 [EXP-001 Async-profiler Phase B Protocol](docs/experiments/EXP-001-async-profiler.md)이 소유한다.

## 기술 스택

- Java 21
- Gradle Wrapper 8.14.4
- Spring Boot 3.5.16
- Spring Data JPA
- Spring JDBC
- Flyway
- PostgreSQL
- JUnit 5
- AssertJ
- Testcontainers PostgreSQL
- Docker Compose

## 로컬 데이터베이스

Docker Compose는 수동 로컬 개발 전용 PostgreSQL 데이터베이스를 실행한다.

- 호스트 포트: `127.0.0.1:55432`
- 데이터베이스: `persistence_lab`
- 사용자명: `lab_user`
- 비밀번호: `lab_password`

이 값들은 로컬 개발 기본값이며 운영 자격 증명이 아니다. 다음 환경 변수로 application datasource 설정을 덮어쓸 수 있다.

- `SPRING_DATASOURCE_URL`
- `SPRING_DATASOURCE_USERNAME`
- `SPRING_DATASOURCE_PASSWORD`
- `LAB_PERSISTENCE_JDBC_BATCH_SIZE`

로컬 lab 데이터베이스 실행 명령:

```powershell
docker compose up -d
docker compose ps
```

Compose 데이터베이스는 수동 로컬 개발용이다. 자동 통합 테스트는 disposable Testcontainers PostgreSQL 데이터베이스를 사용하며 Compose 데이터베이스에 접근하지 않는다.

## 빌드 및 테스트

```powershell
.\gradlew.bat clean build
```

빌드는 Testcontainers PostgreSQL 기반 통합 테스트를 실행한다. 전체 빌드와 테스트를 실행하려면 Docker가 필요하다.

## 스키마

Flyway가 스키마의 기준(Source of Truth)이다. Hibernate는 `ddl-auto: validate`로 설정되어 테이블을 생성하지 않고 스키마를 검증한다.

첫 migration은 합성 `benchmark_record` 테이블을 생성한다.

- IDENTITY 기반 기본 키
- unique `business_key`
- 필수 not-null 제약

## M0 초기 범위

M0에 포함되는 항목:

- 결정적으로 생성되는 합성 입력 command
- JPA `saveAll` 저장과 명시적 `flush`
- 설정 가능한 배치 크기(batch size)를 사용하는 JDBC `JdbcTemplate.batchUpdate` 저장
- JDBC projection 기반 읽기 전용 consistency verification
- row count, key set, duplicate key, missing key, normalized snapshot, SHA-256 checksum 검증

M0에서 제외되는 항목:

- controller 또는 benchmark HTTP endpoint
- M0 범위 안에서 EXP-001 official run 실행
- M0 범위 안에서 공식 50,000건 성능 결과 생성 또는 갱신
- profiler artifact

Phase B에서 추가된 EXP-001 profiling/smoke endpoint는 `exp001` profile에서만 활성화되며 M0 초기 범위와 구분된다.

이 프로젝트는 [MIT License](LICENSE)를 따른다.
