# Results

M0는 별도 승인 없이 official benchmark를 다시 실행하지 않는다.

향후 public reproduction result는 관련 protocol을 실행한 뒤 작은 summary file, elapsed time, environment version, row count, checksum, median calculation을 포함할 수 있다.

이 디렉터리에는 profiler HTML, raw stack trace, JFR file, heap dump, large log, database dump, user absolute path, secret, private artifact, private source information을 저장하지 않는다.

## EXP-001 Results

EXP-001 result structure와 schema는 `docs/experiments/EXP-001-jpa-saveall-vs-jdbc-batch.md`에 정의한다.

EXP-001 layout:

- `results/exp-001/<run-id>/warmup/*.json`
- `results/exp-001/<run-id>/official/*.json`
- `results/exp-001/<run-id>/summary.md`

현재 official public reproduction은 `results/exp-001/20260727T053643Z-2d76b26`에 보존한다. 이 directory의 legacy JSON, `summary.md`, `metadata.md`는 새 formatter나 summary 정책 검증 과정에서 rewrite하지 않는다.

Run ID는 Windows와 macOS harness 모두 UTC timestamp와 short public Git SHA만 사용한다. Run ID에는 user name, user absolute path, host-local secret, private identifier를 포함하지 않는다.

Official summary는 platform별 harness가 동일한 portable `jq` filter로 official JSON 전체와 expected basename/order를 검증한 뒤 생성한다. Invalid, extra, missing, duplicate, unexpected, wrong-order, filename strategy mismatch JSON이 있으면 summary를 확정하지 않는다. Future JSON은 `resultFormatVersion: 2`와 `elapsedSeconds`를 포함하는 UTF-8 no BOM, LF, final newline once pretty JSON으로 저장한다. Legacy와 v2가 섞인 official set은 파일별 schema validation을 통과하면 summary 입력으로 허용한다.
