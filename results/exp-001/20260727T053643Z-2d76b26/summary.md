# EXP-001 Summary

Warm-up 결과는 제외하고 official valid JSON만 사용했다.

## Input Gate

- official JSON: 12
- JPA valid JSON: 6
- JDBC valid JSON: 6
- inputCount/savedCount/rowCount: 50000
- checksum: lowercase SHA-256 형식과 equality 확인

## Metrics

| path | metric | min | max | mean | median | sample stddev | CV |
|---|---:|---:|---:|---:|---:|---:|---:|
| jpa | elapsedNanos | 68130563900.000 | 80403431700.000 | 75210527433.333 | 76684628950.000 | 5035991923.526 | 6.70% |
| jdbc | elapsedNanos | 581862500.000 | 970052500.000 | 689118616.667 | 647975450.000 | 143719774.293 | 20.86% |
| jpa | elapsedMillis | 68130.564 | 80403.432 | 75210.527 | 76684.629 | 5035.992 | 6.70% |
| jdbc | elapsedMillis | 581.863 | 970.053 | 689.119 | 647.975 | 143.720 | 20.86% |
| jpa | rowsPerSecond | 621.86 | 733.89 | 667.37 | 652.10 | 46.10 | 6.91% |
| jdbc | rowsPerSecond | 51543.60 | 85930.95 | 74702.12 | 77262.64 | 12458.34 | 16.68% |

## Comparison

- JDBC median elapsed 기준 time reduction: 99.16%
- JDBC median elapsed 기준 speedup: 118.344960
