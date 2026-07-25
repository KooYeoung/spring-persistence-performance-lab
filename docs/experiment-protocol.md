# Experiment Protocol

M0 validates the correctness foundation only.

M0 validation uses small deterministic inputs and checks:

- saved count
- row count
- business key set
- duplicate business key rollback
- normalized snapshot checksum
- cross-consistency between JPA `saveAll` and JDBC batch persistence

Official performance timing is reserved for EXP-001. M0 must not record official 50,000-row timing, throughput, CPU profile, sampled allocation, or historical reproduction claims.

Any future performance result must be accepted only after consistency checks pass.
