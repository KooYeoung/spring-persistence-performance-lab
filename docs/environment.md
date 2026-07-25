# 환경

M0 기준 환경:

- Java 21
- Gradle Wrapper 8.14.4
- Spring Boot 3.5.16
- PostgreSQL Docker image `postgres:17.6-alpine`
- Docker Compose

Application은 환경 변수로 덮어쓸 수 있는 안전한 local datasource default를 사용한다. Production profile이나 production datasource value는 포함하지 않는다.

## Logging

SQL logging은 기본적으로 비활성화한다.

- `spring.jpa.show-sql=false`
- `logging.level.org.hibernate.SQL=OFF`
- `logging.level.org.hibernate.orm.jdbc.bind=OFF`

SQL logging, bind logging, Hibernate statistics, profiler agent, verbose container logging은 timing에 영향을 줄 수 있다. Official timing은 EXP-001에서만 수행하며 M0에서는 생성하지 않는다.

## EXP-001 환경 정책

EXP-001 세부 환경 규칙은 `docs/experiments/EXP-001-jpa-saveall-vs-jdbc-batch.md`에 정의한다.

공통 환경 정책:

- Java, Gradle, Spring Boot, PostgreSQL, Docker, OS, CPU, memory, disk, Git revision, active profile, sanitized datasource URL, logging settings, Hikari settings, transaction isolation을 기록한다.
- secret, user absolute path, DB dump, profiler raw artifact, private source information은 기록하지 않는다.
- official timing에서는 SQL logging, bind logging, Hibernate statistics, debugger, profiler agent를 비활성화한다.

Gradle process option과 benchmark JVM option은 구분한다.

- Gradle execution은 `bootJar` 생성 시 `--no-daemon`, `--max-workers=1` 같은 옵션을 사용할 수 있다.
- `-Xms2g`, `-Xmx2g`, `-XX:+UseG1GC`, `-Duser.timezone=UTC` 같은 benchmark JVM option은 platform별 EXP-001 `start` action이 실행하는 `java -jar` process에 적용해야 한다.

EXP-001 harness는 Windows에서 `scripts\exp-001\windows\exp001.cmd`, macOS에서 `./scripts/exp-001/macos/exp001.sh`를 사용한다. local `psql`과 system-wide `jq` 설치를 요구하지 않으며, DB 확인은 Docker Compose PostgreSQL service 내부 `psql`, JSON 처리는 `scripts/exp-001/tools/jq.lock`에 고정된 portable `jq`를 사용한다.

이 문서는 EXP-001 script harness의 세부 실행 순서를 소유하지 않는다. EXP-001 세부 규칙은 `docs/experiments/EXP-001-jpa-saveall-vs-jdbc-batch.md`가 소유한다.
