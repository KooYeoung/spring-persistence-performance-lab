# Results

M0는 official benchmark result를 공개하지 않는다.

향후 public reproduction result는 관련 protocol을 실행한 뒤 작은 summary file, elapsed time, environment version, row count, checksum, median calculation을 포함할 수 있다.

이 디렉터리에는 profiler HTML, raw stack trace, JFR file, heap dump, large log, database dump, user absolute path, secret, private artifact, private source information을 저장하지 않는다.

## EXP-001 Results

EXP-001 result structure와 schema는 `docs/experiments/EXP-001-jpa-saveall-vs-jdbc-batch.md`에 정의한다.

향후 예상 layout:

- `results/exp-001/<run-id>/warmup/*.json`
- `results/exp-001/<run-id>/official/*.json`
- `results/exp-001/<run-id>/summary.md`

승인된 script-first harness가 clean public revision에서 official public reproduction을 실행하기 전까지 EXP-001 result file은 존재하지 않는다.

Run ID는 Windows와 macOS harness 모두 UTC timestamp와 short public Git SHA만 사용한다. Run ID에는 user name, user absolute path, host-local secret, private identifier를 포함하지 않는다.

Official summary는 platform별 harness가 동일한 portable `jq` filter로 official JSON 전체를 검증한 뒤 생성한다. Invalid, extra, unknown path JSON이 있으면 summary를 확정하지 않는다.
