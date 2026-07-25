# Environment

M0 targets:

- Java 21
- Gradle Wrapper 8.14.4
- Spring Boot 3.5.16
- PostgreSQL Docker image `postgres:17.6-alpine`
- Docker Compose

The application uses safe local datasource defaults that can be overridden with environment variables. No production profile or production datasource value is included.

## Logging

SQL logging is disabled by default:

- `spring.jpa.show-sql=false`
- `logging.level.org.hibernate.SQL=OFF`
- `logging.level.org.hibernate.orm.jdbc.bind=OFF`

SQL logging, bind logging, Hibernate statistics, profiler agents, and verbose container logging can affect timing. Official timing is reserved for EXP-001 and is not produced in M0.
