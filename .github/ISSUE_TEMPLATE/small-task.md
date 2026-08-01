---
name: 작은 단위 작업
about: 목적과 완료 조건이 분명한 작은 변경을 제안합니다.
title: ""
labels: ""
assignees: ""
---

## 목적

- 해결하려는 실제 문제:
- 왜 지금 필요한가:
- 관련 Source of Truth 또는 근거:

## 범위

- 변경 대상:
- 포함할 작업:
- 예상 변경 파일 수:

## 제외 범위 또는 Non-goal

- 포함하지 않을 작업:
- 별도 Issue로 분리할 작업:
- 실행하지 않을 검증 또는 실험:

## 완료 조건

- [ ] Issue 목적이 하나의 독립 결과로 제한된다.
- [ ] 변경 파일 범위가 명시되어 있다.
- [ ] Source of Truth와 충돌하지 않는다.
- [ ] 필요한 검증 명령과 기대 결과가 명시되어 있다.
- [ ] 실행하지 않은 항목은 `NOT_RUN`으로 기록한다.
- [ ] `BLOCKED`, `PARTIAL`, `UNVERIFIED`, `NOT_RUN`을 성공으로 표현하지 않는다.

## 검증 방법

- 실행할 명령:
- 확인할 결과:
- 실행하지 않는 검증과 이유:

## Evidence

- 필요한 Evidence:
- Evidence가 필요하지 않은 경우: `NOT_APPLICABLE`
- `NOT_APPLICABLE` 사유:

## 중단 조건

- working tree 또는 index 상태가 예상과 다름
- 완료 조건이 작업 중 증가함
- 하나의 Issue가 둘 이상의 독립 결과를 포함함
- 직접 Evidence 없이 `PASS` 판정이 필요함
- 지원 도구, fixture, parser, schema, validator, wrapper가 핵심 작업보다 커짐
- 원인을 확인할 수 없어 `UNVERIFIED` 또는 `BLOCKED`로 남겨야 함

## 사람 승인 경계

- [ ] commit 승인
- [ ] push 승인
- [ ] PR 생성 승인
- [ ] Issue 또는 PR comment 작성 승인
- [ ] merge 승인
- [ ] test/build/benchmark/profiler 실행 승인
- [ ] repository 또는 GitHub mutation 승인
