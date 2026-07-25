# spring-persistence-performance-lab

Public Spring Boot persistence benchmark foundation for comparing a synthetic JPA `saveAll` path with a Spring JDBC batch path.

M0 validates correctness only. It does not execute EXP-001 and does not publish official 50,000-row timing, throughput, CPU profile, or allocation results.

## Technology

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

## Local Database

Docker Compose starts a local development PostgreSQL database only:

- Host port: `127.0.0.1:55432`
- Database: `persistence_lab`
- Username: `lab_user`
- Password: `lab_password`

These are local development defaults, not production credentials. Environment variables may override the application datasource settings:

- `SPRING_DATASOURCE_URL`
- `SPRING_DATASOURCE_USERNAME`
- `SPRING_DATASOURCE_PASSWORD`
- `LAB_PERSISTENCE_JDBC_BATCH_SIZE`

Start the local lab database:

```powershell
docker compose up -d
docker compose ps
```

The Compose database is for manual local development. Automated integration tests use disposable Testcontainers PostgreSQL databases and do not access the Compose database.

## Build And Test

```powershell
.\gradlew.bat clean build
```

The build runs integration tests against Testcontainers PostgreSQL. Docker must be available.

## Schema

Flyway is the schema Source of Truth. Hibernate is configured with `ddl-auto: validate`, so it validates the schema instead of creating tables.

The first migration creates the synthetic `benchmark_record` table with:

- identity primary key
- unique `business_key`
- required not-null constraints

## M0 Scope

M0 includes:

- deterministic synthetic input commands
- JPA `saveAll` persistence with explicit `flush`
- JDBC `JdbcTemplate.batchUpdate` persistence with configurable batch size
- read-only consistency verification using a JDBC projection
- row count, key set, duplicate key, missing key, normalized snapshot, and SHA-256 checksum validation

M0 excludes:

- controller or benchmark HTTP endpoint
- EXP-001 official run
- 50,000-row performance result publication
- profiler artifacts
- GitHub publishing
- license selection

The license decision is still pending.
