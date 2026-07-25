# EXP-001 script harness

이 디렉터리는 EXP-001을 script-first 방식으로 실행하기 위한 외부 실험 하네스이다.

애플리케이션은 `exp001` profile에서 최소 HTTP endpoint만 제공한다. 애플리케이션 시작과 종료, DB safety gate, reset, warm-up, official round 실행, timeout, 결과 저장, summary 계산은 이 script들이 담당한다.

## 준비

```bash
bash scripts/exp-001/00_prepare.sh
```

`00_prepare.sh`는 `.env`가 없을 때 `.env.example`을 복사한다. 공식 실행 전에는 `.env`를 열어 값을 확인하고, destructive reset을 허용할 때만 `ALLOW_DESTRUCTIVE_RESET=true`로 바꾼다.

## 실행 순서

```bash
bash scripts/exp-001/01_start_app.sh
bash scripts/exp-001/02_check_environment.sh
bash scripts/exp-001/03_run_benchmark.sh
bash scripts/exp-001/04_generate_summary.sh
bash scripts/exp-001/05_stop_app.sh
```

이번 구현 검증 단계에서는 `03_run_benchmark.sh`를 실행하지 않는다. 이 script는 공식 EXP-001 timing set을 생성하므로 별도 실행 승인과 환경 확인이 필요하다.

## Safety Gate

DB reset은 다음 조건이 모두 일치할 때만 수행된다.

- `ALLOW_DESTRUCTIVE_RESET=true`
- `DB_HOST`가 정확히 `localhost` 또는 `127.0.0.1`
- `DB_PORT=55432`
- `DB_NAME=persistence_lab`
- `DB_USER=lab_user`
- `current_database()`가 `persistence_lab`
- `current_user`가 `lab_user`
- `transaction_isolation`이 `read committed`

하나라도 실패하면 reset, warm-up, official run을 중단한다.

## 결과

결과는 project root 기준 `RESULT_ROOT` 아래에 저장된다. 기본값은 `results/exp-001`이다. Run ID는 UTC timestamp와 short public Git SHA만 사용하며 사용자명, host-local absolute path, secret을 포함하지 않는다.

`summary.md`는 official JSON이 JPA 6개, JDBC 6개로 모두 `valid=true`일 때만 생성한다. Warm-up JSON은 보존하지만 공식 통계에는 포함하지 않는다.
