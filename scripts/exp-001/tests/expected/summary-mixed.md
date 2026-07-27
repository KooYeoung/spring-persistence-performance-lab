# EXP-001 Summary

Warm-up 결과는 제외하고 official valid JSON만 사용했다.

## Run Metadata

- official JSON: 12
- JPA valid JSON: 6
- JDBC valid JSON: 6
- inputCount/savedCount/rowCount: 50000
- result schema: legacy와 v2를 파일별로 검증
- elapsed source of truth: elapsedNanos
- checksum: lowercase SHA-256 형식과 equality 확인
- warm-up: excluded
- p95: excluded

## Official Run Table

| Sequence | Round | Strategy | Elapsed | Seconds | Milliseconds | Nanoseconds | Rows/s | Valid |
|---:|---:|---|---:|---:|---:|---:|---:|---|
| 1 | 1 | jpa | 1.000s | 1.000000000 | 1000.000 | 1000000000 | 50000.00 | true |
| 2 | 1 | jdbc | 500.000ms | 0.500000000 | 500.000 | 500000000 | 100000.00 | true |
| 3 | 2 | jdbc | 600.000ms | 0.600000000 | 600.000 | 600000000 | 83333.33 | true |
| 4 | 2 | jpa | 2.000s | 2.000000000 | 2000.000 | 2000000000 | 25000.00 | true |
| 5 | 3 | jpa | 3.000s | 3.000000000 | 3000.000 | 3000000000 | 16666.67 | true |
| 6 | 3 | jdbc | 700.000ms | 0.700000000 | 700.000 | 700000000 | 71428.57 | true |
| 7 | 4 | jdbc | 800.000ms | 0.800000000 | 800.000 | 800000000 | 62500.00 | true |
| 8 | 4 | jpa | 4.000s | 4.000000000 | 4000.000 | 4000000000 | 12500.00 | true |
| 9 | 5 | jpa | 5.000s | 5.000000000 | 5000.000 | 5000000000 | 10000.00 | true |
| 10 | 5 | jdbc | 900.000ms | 0.900000000 | 900.000 | 900000000 | 55555.56 | true |
| 11 | 6 | jdbc | 1.000s | 1.000000000 | 1000.000 | 1000000000 | 50000.00 | true |
| 12 | 6 | jpa | 6.000s | 6.000000000 | 6000.000 | 6000000000 | 8333.33 | true |

## Statistical Summary

| Strategy | Metric | Min | Max | Mean | Median | Sample Stddev | CV |
|---|---|---:|---:|---:|---:|---:|---:|
| jpa | elapsedSeconds | 1.000000000 | 6.000000000 | 3.500000000 | 3.500000000 | 1.870828693 | 53.45% |
| jdbc | elapsedSeconds | 0.500000000 | 1.000000000 | 0.750000000 | 0.750000000 | 0.187082869 | 24.94% |
| jpa | elapsedMillis | 1000.000 | 6000.000 | 3500.000 | 3500.000 | 1870.829 | 53.45% |
| jdbc | elapsedMillis | 500.000 | 1000.000 | 750.000 | 750.000 | 187.083 | 24.94% |
| jpa | elapsedNanos | 1000000000.000 | 6000000000.000 | 3500000000.000 | 3500000000.000 | 1870828693.387 | 53.45% |
| jdbc | elapsedNanos | 500000000.000 | 1000000000.000 | 750000000.000 | 750000000.000 | 187082869.339 | 24.94% |

## Median Unit Overview

| Strategy | Seconds | Milliseconds | Nanoseconds |
|---|---:|---:|---:|
| jpa | 3.500000000 | 3500.000 | 3500000000.000 |
| jdbc | 0.750000000 | 750.000 | 750000000.000 |

## Throughput Summary

| Strategy | Metric | Min | Max | Mean | Median | Sample Stddev | CV |
|---|---|---:|---:|---:|---:|---:|---:|
| jpa | rowsPerSecond | 8333.33 | 50000.00 | 20416.67 | 14583.33 | 15668.00 | 76.74% |
| jdbc | rowsPerSecond | 50000.00 | 100000.00 | 70469.58 | 66964.29 | 18672.91 | 26.50% |

## Derived Comparison

- Median speedup: 4.666667
- JDBC median elapsed reduction: 78.57%
- Mean speedup: 4.666667

## Interpretation Boundary

이 summary는 official JSON 12개만 집계한다. Warm-up, p95, profiler output, 다른 OS/JVM/DB/hardware 일반화는 포함하지 않는다.
