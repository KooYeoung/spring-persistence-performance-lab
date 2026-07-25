# 실험 프로토콜

M0는 정합성 기반만 검증한다.

M0 검증은 작은 deterministic input을 사용하며 다음을 확인한다.

- saved count
- row count
- business key set
- duplicate business key rollback
- normalized snapshot checksum
- JPA `saveAll`과 JDBC batch persistence의 cross-consistency

공식 성능 timing은 EXP-001에서만 다룬다. M0는 official 50,000-row timing, throughput, CPU profile, sampled allocation 또는 historical reproduction claim을 기록하지 않는다.

향후 성능 결과는 consistency check가 모두 통과한 뒤에만 채택할 수 있다.

## EXP-001

EXP-001의 단일 Source of Truth는 다음 문서이다.

- `docs/experiments/EXP-001-jpa-saveall-vs-jdbc-batch.md`

EXP-001의 input count, warm-up count, official run count, execution order, timing boundary, DB safety gate, invalid run policy, result schema 같은 세부 규칙은 위 문서가 소유한다.

이 문서는 공통 실험 정책만 유지한다.

- official timing은 clean public revision에서 실행한다.
- command generation, DB reset, consistency verification, result writing은 measured persistence timing 밖에 둔다.
- profiler output은 official timing representative value와 섞지 않는다.
- official result는 consistency verification이 통과한 뒤에만 채택한다.
