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

## 기본 실험 기록

새 실험은 별도 schema 없이 `질문`, `가설`, `조건`, `실행 방법`, `정합성 결과`, `성능 결과`, `해석`, `한계`, `다음 질문`을 Markdown에 기록한다.

성능 비교 실험은 기본 3~5회 반복하고 median을 대표값으로 사용한다. 정합성 또는 동작 확인 실험에는 불필요한 반복 측정을 강제하지 않는다.

성능 수치와 profiler 결과는 분리한다. 병목 원인 확인이 필요한 경우에만 목적에 따라 `wall`, `cpu`, `alloc` 중 하나를 선택하고, HTML/Flat 직접 출력 또는 JFR을 상황에 맞게 선택한다.

실행하지 않은 항목은 `NOT_RUN` 또는 `NOT_APPLIED` 등으로 기록하고 성공으로 표현하지 않는다.

## EXP-001

EXP-001의 단일 Source of Truth는 다음 문서이다.

- `docs/experiments/EXP-001-jpa-saveall-vs-jdbc-batch.md`

EXP-001의 input count, warm-up count, official run count, execution order, timing boundary, DB safety gate, invalid run policy, result schema 같은 세부 규칙은 위 문서가 소유한다.

이 문서는 공통 실험 정책만 유지한다.

- official timing은 clean public revision에서 실행한다.
- command generation, DB reset, consistency verification, result writing은 measured persistence timing 밖에 둔다.
- profiler output은 official timing representative value와 섞지 않는다.
- official result는 consistency verification이 통과한 뒤에만 채택한다.
