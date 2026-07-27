# EXP-001 실행 Metadata

## Run Identity

- experiment: `EXP-001`
- run ID: `20260727T053643Z-2d76b26`
- source revision: `2d76b26e716a5f1e471f225afe66128ebc948b26`
- execution time: `2026-07-27T05:36:43Z`
- result status: official run succeeded

## Environment

- OS: Windows 11 Home
- architecture: AMD64
- PowerShell: 5.1.26100.8875 Desktop
- execution boundary: SAME_USER_NON_ADMIN
- Java distribution: Amazon Corretto
- Java version: 21.0.11
- Spring profile: `exp001`
- Docker Engine: 29.1.3
- Docker Compose: v2.40.3-desktop.1
- PostgreSQL image: `postgres:17.6-alpine`

## Datasource and Runtime Configuration

- datasource host: `localhost`
- datasource port: `55432`
- datasource database: `persistence_lab`
- datasource user: `lab_user`
- transaction isolation: `read committed`
- Hibernate DDL mode: `validate`
- Hibernate batch size: not configured
- Hibernate `order_inserts`: not configured
- JDBC batch size: `1000`
- `rewriteBatchedInserts`: not configured
- Hikari `maximumPoolSize`: `4`
- Hikari `minimumIdle`: `1`
- Hikari connection timeout: `30000ms`
- SQL logging: OFF
- Hibernate bind logging: OFF
- Hibernate statistics: OFF

## Protocol

- input count: `50,000`
- input generation: deterministic
- warm-up: JPA 1회, JDBC 1회
- official runs: JPA 6회, JDBC 6회, total 12회
- alternating order: odd rounds JPA -> JDBC, even rounds JDBC -> JPA
- DB reset: `TRUNCATE TABLE benchmark_record RESTART IDENTITY`
- reset count: `14`
- timing boundary: transactional service proxy 호출 직전부터 반환 직후까지
- transaction commit: included
- consistency verification: outside timer
- primary statistic: median
- reference statistics: min, max, mean, sample standard deviation, CV
- profiler: OFF
- k6: OFF
- p95: excluded

## Validation

- official JSON: 12/12 valid
- JPA official JSON: 6
- JDBC official JSON: 6
- warm-up JSON: 2
- invalid JSON: 0
- partial result: 0
- `valid=false`: 0
- `inputCount`, `savedCount`, `rowCount`, `distinctBusinessKeyCount`: all `50,000`
- `missingKeyCount`, `unexpectedKeyCount`, `duplicateKeyCount`: all `0`
- checksum: all expected and actual values matched
- alternating order: passed
- summary raw recalculation: matched
- encoding: UTF-8 without BOM

## Official Run Index

이 표는 official raw JSON 12개에서 파생한 가독성용 index이다. Raw JSON은 수정하지 않는다.

| Run | Round | Order | Path | Duration | Exact Units | Rows/s | Valid | Raw |
|---:|---:|---:|---|---:|---:|---:|---|---|
| 1 | 1 | 1 | `jpa` | 1m 15.858s | 75,857.632 ms · 75,857,631,900 ns | 659.13 | true | [round-01-01-jpa.json](official/round-01-01-jpa.json) |
| 2 | 1 | 2 | `jdbc` | 597.548 ms | 597.548 ms · 597,548,100 ns | 83,675.27 | true | [round-01-02-jdbc.json](official/round-01-02-jdbc.json) |
| 3 | 2 | 1 | `jdbc` | 970.053 ms | 970.053 ms · 970,052,500 ns | 51,543.60 | true | [round-02-01-jdbc.json](official/round-02-01-jdbc.json) |
| 4 | 2 | 2 | `jpa` | 1m 19.340s | 79,340.273 ms · 79,340,273,300 ns | 630.20 | true | [round-02-02-jpa.json](official/round-02-02-jpa.json) |
| 5 | 3 | 1 | `jpa` | 1m 20.403s | 80,403.432 ms · 80,403,431,700 ns | 621.86 | true | [round-03-01-jpa.json](official/round-03-01-jpa.json) |
| 6 | 3 | 2 | `jdbc` | 671.197 ms | 671.197 ms · 671,196,500 ns | 74,493.83 | true | [round-03-02-jdbc.json](official/round-03-02-jdbc.json) |
| 7 | 4 | 1 | `jdbc` | 624.754 ms | 624.754 ms · 624,754,400 ns | 80,031.45 | true | [round-04-01-jdbc.json](official/round-04-01-jdbc.json) |
| 8 | 4 | 2 | `jpa` | 1m 10.020s | 70,019.638 ms · 70,019,637,800 ns | 714.09 | true | [round-04-02-jpa.json](official/round-04-02-jpa.json) |
| 9 | 5 | 1 | `jpa` | 1m 17.512s | 77,511.626 ms · 77,511,626,000 ns | 645.06 | true | [round-05-01-jpa.json](official/round-05-01-jpa.json) |
| 10 | 5 | 2 | `jdbc` | 689.298 ms | 689.298 ms · 689,297,700 ns | 72,537.60 | true | [round-05-02-jdbc.json](official/round-05-02-jdbc.json) |
| 11 | 6 | 1 | `jdbc` | 581.863 ms | 581.863 ms · 581,862,500 ns | 85,930.95 | true | [round-06-01-jdbc.json](official/round-06-01-jdbc.json) |
| 12 | 6 | 2 | `jpa` | 1m 08.131s | 68,130.564 ms · 68,130,563,900 ns | 733.89 | true | [round-06-02-jpa.json](official/round-06-02-jpa.json) |

## Median Unit Overview

| Path | Human-readable | Seconds | Milliseconds | Nanoseconds |
|---|---:|---:|---:|---:|
| `jpa` | 1m 16.685s | 76.685 s | 76,684.629 ms | 76,684,628,950 ns |
| `jdbc` | 647.975 ms | 0.648 s | 647.975 ms | 647,975,450 ns |

## Derived Comparison

- median speedup: 118.344960x
- JDBC median elapsed reduction: 99.155013%
- mean speedup: 109.140176x

위 값은 단일 Windows official execution에서 파생했다. Warm-up 결과는 제외했고, profiler와 k6는 OFF였다. 보편적인 성능 보장이 아니다.

## Result References

- summary: [summary.md](summary.md)
- official raw JSON: [official/](official/)
- warm-up raw JSON: [warmup/](warmup/)

## Source of Truth

- raw measurements: official JSON files
- official statistics: [summary.md](summary.md)
- metadata tables: raw JSON과 summary statistics에서 파생한 human-readable view

## Interpretation Boundary

- 이 결과는 하나의 Windows 환경에서 수행한 단일 official execution이다.
- Warm-up 결과는 official statistics에 포함하지 않는다.
- Profiler와 k6는 사용하지 않았다.
- 다른 OS, JVM, DB, hardware에서는 결과가 달라질 수 있다.
- 이 official result는 이전 smoke 또는 private historical result와 구분한다.
