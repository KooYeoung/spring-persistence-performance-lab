# 결과 정합성

Consistency verifier는 read-only 역할이며 synthetic table의 JDBC projection을 사용한다.

Verifier는 다음을 확인한다.

- total row count
- distinct business key count
- missing expected business keys
- unexpected business keys
- duplicate business keys
- normalized row snapshot
- SHA-256 checksum

Normalized checksum에 포함되는 값:

- `businessKey`
- `name`
- `numericValue`
- `occurredOn`

Normalized checksum에서 제외되는 값:

- `id`
- `createdAt`

Row는 `businessKey` 오름차순으로 정렬한다. Text는 UTF-8로 encoding한다. Null value는 fixed field encoding `-1:`을 사용한다. Non-null field는 `<UTF-8 byte length>:<value>`로 encoding한다. `occurredOn`은 `ISO_LOCAL_DATE`를 사용한다. `numericValue`는 scale 4의 plain string으로 format한다. Column에는 fixed delimiter를 사용하고 row에는 `\n`을 사용한다. 최종 checksum은 lowercase hexadecimal SHA-256이다.

두 persistence path의 row count와 business key set이 같더라도 checksum이 다르면 consistency verification은 실패한다.

## Official Result Gate

Official performance result는 consistency verification이 성공한 뒤에만 채택할 수 있다.

EXP-001-specific gate는 `docs/experiments/EXP-001-jpa-saveall-vs-jdbc-batch.md`에 정의한다.

공통 invalid result 조건:

- row count mismatch
- key set mismatch
- checksum mismatch
- duplicate business key
- missing expected business key
- saved count mismatch
- transaction failure
- DB connection failure
- non-positive elapsed time

Invalid run은 raw result record에 유지하며 successful run으로 덮어쓰지 않는다.
