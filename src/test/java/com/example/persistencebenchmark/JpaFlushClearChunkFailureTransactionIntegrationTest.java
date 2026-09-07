package com.example.persistencebenchmark;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import java.util.stream.IntStream;
import java.util.stream.Stream;

import com.example.persistencebenchmark.consistency.ConsistencyReport;
import com.example.persistencebenchmark.domain.BenchmarkRecord;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import org.hibernate.exception.ConstraintViolationException;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.domain.EntityScan;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;

@EntityScan(basePackageClasses = BenchmarkRecord.class)
class JpaFlushClearChunkFailureTransactionIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    private static final Instant CREATED_AT = Instant.parse("2024-01-01T00:00:00Z");
    private static final String CONSTRAINT_NAME = "uk_benchmark_record_business_key";
    private static final String UNIQUE_VIOLATION_SQL_STATE = "23505";

    @Autowired
    private TransactionTemplate transactionTemplate;

    @PersistenceContext
    private EntityManager entityManager;

    @Test
    void secondChunkFailureRollsBackAccordingToTransactionBoundary() {
        String runSuffix = UUID.randomUUID().toString().replace("-", "");
        List<BenchmarkRecordCommand> singleTransactionCommands = scenarioCommands("exp012-single-" + runSuffix);
        List<BenchmarkRecordCommand> transactionPerChunkCommands = scenarioCommands("exp012-per-chunk-" + runSuffix);

        assertThat(Stream.concat(singleTransactionCommands.stream(), transactionPerChunkCommands.stream())
                .map(BenchmarkRecordCommand::businessKey)
                .toList())
                .doesNotHaveDuplicates()
                .allMatch(key -> key.length() <= 64);

        AtomicReference<FailureObservation> singleTransactionFailure = new AtomicReference<>();
        AtomicReference<FailurePhase> singleTransactionPhase = new AtomicReference<>(FailurePhase.NOT_STARTED);
        AtomicReference<CommittedChunkObservation> committedChunk = new AtomicReference<>();
        AtomicReference<FailureObservation> transactionPerChunkFailure = new AtomicReference<>();
        AtomicReference<FailurePhase> transactionPerChunkPhase = new AtomicReference<>(FailurePhase.NOT_STARTED);
        AtomicReference<CleanupObservation> cleanupResult = new AtomicReference<>();

        try {
            RuntimeException singleTransactionException = assertThrows(RuntimeException.class, () ->
                    transactionTemplate.executeWithoutResult(status -> {
                        BenchmarkRecord entityA = BenchmarkRecord.from(singleTransactionCommands.get(0), CREATED_AT);
                        BenchmarkRecord entityB = BenchmarkRecord.from(singleTransactionCommands.get(1), CREATED_AT);
                        BenchmarkRecord entityC = BenchmarkRecord.from(singleTransactionCommands.get(2), CREATED_AT);
                        BenchmarkRecord entityD = BenchmarkRecord.from(singleTransactionCommands.get(3), CREATED_AT);

                        entityManager.persist(entityA);
                        entityManager.persist(entityB);
                        List<Boolean> chunkOneManagedAfterPersist = contains(entityA, entityB);

                        entityManager.flush();
                        List<Boolean> chunkOneManagedAfterFlush = contains(entityA, entityB);

                        entityManager.clear();
                        List<EntitySnapshot> chunkOneAfterClear = snapshots(entityA, entityB);

                        entityManager.persist(entityC);
                        entityManager.persist(entityD);
                        String dirtyBusinessKeyBefore = entityC.getBusinessKey();
                        ReflectionTestUtils.setField(
                                entityC,
                                "businessKey",
                                singleTransactionCommands.get(0).businessKey()
                        );

                        singleTransactionFailure.set(new FailureObservation(
                                "single-transaction",
                                chunkOneManagedAfterPersist,
                                chunkOneManagedAfterFlush,
                                chunkOneAfterClear,
                                snapshots(entityC, entityD),
                                dirtyBusinessKeyBefore,
                                entityC.getBusinessKey(),
                                FailurePhase.SECOND_CHUNK_EXPLICIT_FLUSH_STARTED,
                                4,
                                2,
                                2
                        ));
                        singleTransactionPhase.set(FailurePhase.SECOND_CHUNK_EXPLICIT_FLUSH_STARTED);

                        entityManager.flush();
                        singleTransactionPhase.set(FailurePhase.UNEXPECTEDLY_COMPLETED);
                    })
            );

            FailureObservation singleObservation = Objects.requireNonNull(
                    singleTransactionFailure.get(),
                    "single transaction failure observation must not be null"
            );
            assertFailureObservation(singleObservation, singleTransactionCommands, "single-transaction");
            assertThat(singleTransactionPhase.get()).isEqualTo(FailurePhase.SECOND_CHUNK_EXPLICIT_FLUSH_STARTED);
            ConstraintIdentity singleConstraint = expectedConstraintIdentity(singleTransactionException);
            assertThat(singleConstraint.sqlState()).isEqualTo(UNIQUE_VIOLATION_SQL_STATE);
            assertThat(singleConstraint.constraintName()).isEqualTo(CONSTRAINT_NAME);

            List<Long> singleTransactionRowCounts = transactionTemplate.execute(status ->
                    singleObservation.ids().stream().map(this::countById).toList()
            );
            assertThat(singleTransactionRowCounts).isNotNull().containsExactly(0L, 0L, 0L, 0L);

            ConsistencyReport emptyReport = verifyExpected(List.of());
            assertThat(emptyReport.rowCount()).isZero();
            assertThat(emptyReport.hasFailures()).as(emptyReport.failureSummary()).isFalse();

            CommittedChunkObservation firstChunk = transactionTemplate.execute(status -> {
                BenchmarkRecord entityA = BenchmarkRecord.from(transactionPerChunkCommands.get(0), CREATED_AT);
                BenchmarkRecord entityB = BenchmarkRecord.from(transactionPerChunkCommands.get(1), CREATED_AT);

                entityManager.persist(entityA);
                entityManager.persist(entityB);
                List<Boolean> managedAfterPersist = contains(entityA, entityB);

                entityManager.flush();
                List<Boolean> managedAfterFlush = contains(entityA, entityB);

                entityManager.clear();
                return new CommittedChunkObservation(
                        managedAfterPersist,
                        managedAfterFlush,
                        snapshots(entityA, entityB)
                );
            });
            assertThat(firstChunk).isNotNull();
            committedChunk.set(firstChunk);
            assertCommittedChunkObservation(firstChunk, transactionPerChunkCommands.subList(0, 2));

            RuntimeException transactionPerChunkException = assertThrows(RuntimeException.class, () ->
                    transactionTemplate.executeWithoutResult(status -> {
                        BenchmarkRecord entityC = BenchmarkRecord.from(
                                transactionPerChunkCommands.get(2),
                                CREATED_AT
                        );
                        BenchmarkRecord entityD = BenchmarkRecord.from(
                                transactionPerChunkCommands.get(3),
                                CREATED_AT
                        );

                        entityManager.persist(entityC);
                        entityManager.persist(entityD);
                        String dirtyBusinessKeyBefore = entityC.getBusinessKey();
                        ReflectionTestUtils.setField(
                                entityC,
                                "businessKey",
                                transactionPerChunkCommands.get(0).businessKey()
                        );

                        transactionPerChunkFailure.set(new FailureObservation(
                                "transaction-per-chunk",
                                firstChunk.managedAfterPersist(),
                                firstChunk.managedAfterFlush(),
                                firstChunk.afterClear(),
                                snapshots(entityC, entityD),
                                dirtyBusinessKeyBefore,
                                entityC.getBusinessKey(),
                                FailurePhase.SECOND_CHUNK_EXPLICIT_FLUSH_STARTED,
                                4,
                                2,
                                2
                        ));
                        transactionPerChunkPhase.set(FailurePhase.SECOND_CHUNK_EXPLICIT_FLUSH_STARTED);

                        entityManager.flush();
                        transactionPerChunkPhase.set(FailurePhase.UNEXPECTEDLY_COMPLETED);
                    })
            );

            FailureObservation perChunkObservation = Objects.requireNonNull(
                    transactionPerChunkFailure.get(),
                    "transaction-per-chunk failure observation must not be null"
            );
            assertFailureObservation(
                    perChunkObservation,
                    transactionPerChunkCommands,
                    "transaction-per-chunk"
            );
            assertThat(transactionPerChunkPhase.get()).isEqualTo(FailurePhase.SECOND_CHUNK_EXPLICIT_FLUSH_STARTED);
            ConstraintIdentity perChunkConstraint = expectedConstraintIdentity(transactionPerChunkException);
            assertThat(perChunkConstraint.sqlState()).isEqualTo(UNIQUE_VIOLATION_SQL_STATE);
            assertThat(perChunkConstraint.constraintName()).isEqualTo(CONSTRAINT_NAME);

            ReadObservation readObservation = transactionTemplate.execute(status -> {
                List<RowSnapshot> committedRows = firstChunk.ids().stream()
                        .map(id -> {
                            BenchmarkRecord row = entityManager.find(BenchmarkRecord.class, id);
                            assertThat(row).isNotNull();
                            return rowSnapshot(row);
                        })
                        .toList();
                List<Long> failedRowCounts = perChunkObservation.chunkTwoIds().stream()
                        .map(this::countById)
                        .toList();
                return new ReadObservation(committedRows, failedRowCounts);
            });

            assertThat(readObservation).isNotNull();
            assertThat(readObservation.committedRows()).hasSize(2);
            for (int index = 0; index < 2; index++) {
                assertRowMatches(
                        readObservation.committedRows().get(index),
                        transactionPerChunkCommands.get(index),
                        firstChunk.ids().get(index)
                );
            }
            assertThat(readObservation.failedRowCounts()).containsExactly(0L, 0L);

            ConsistencyReport committedReport = verifyExpected(transactionPerChunkCommands.subList(0, 2));
            assertThat(committedReport.rowCount()).isEqualTo(2);
            assertThat(committedReport.hasFailures()).as(committedReport.failureSummary()).isFalse();
        } finally {
            List<Long> idsToDelete = Stream.of(
                            singleTransactionFailure.get(),
                            transactionPerChunkFailure.get()
                    )
                    .filter(Objects::nonNull)
                    .flatMap(observation -> observation.ids().stream())
                    .collect(ArrayList::new, ArrayList::add, ArrayList::addAll);
            CommittedChunkObservation committedObservation = committedChunk.get();
            if (committedObservation != null) {
                idsToDelete.addAll(committedObservation.ids());
            }
            List<Long> distinctIds = idsToDelete.stream()
                    .filter(Objects::nonNull)
                    .distinct()
                    .toList();

            CleanupObservation cleanup = transactionTemplate.execute(status -> {
                int deletedRows = distinctIds.stream()
                        .mapToInt(id -> jdbcTemplate().update("DELETE FROM benchmark_record WHERE id = ?", id))
                        .sum();
                long remainingRows = distinctIds.stream().mapToLong(this::countById).sum();
                return new CleanupObservation(distinctIds.size(), deletedRows, remainingRows);
            });
            cleanupResult.set(cleanup);
        }

        CleanupObservation cleanup = Objects.requireNonNull(
                cleanupResult.get(),
                "cleanup observation must not be null"
        );
        assertThat(cleanup.capturedIdCount()).isEqualTo(8);
        assertThat(cleanup.deletedRowCount()).isEqualTo(2);
        assertThat(cleanup.remainingRowCount()).isZero();
    }

    private List<BenchmarkRecordCommand> scenarioCommands(String namespace) {
        List<BenchmarkRecordCommand> seeds = generatedCommands(4);
        return IntStream.range(0, seeds.size())
                .mapToObj(index -> {
                    BenchmarkRecordCommand seed = seeds.get(index);
                    return new BenchmarkRecordCommand(
                            namespace + "-" + (char) ('a' + index),
                            seed.name(),
                            seed.numericValue(),
                            seed.occurredOn()
                    );
                })
                .toList();
    }

    private void assertFailureObservation(
            FailureObservation observation,
            List<BenchmarkRecordCommand> commands,
            String expectedScenario
    ) {
        assertThat(observation.scenario()).isEqualTo(expectedScenario);
        assertThat(observation.chunkOneManagedAfterPersist()).containsExactly(true, true);
        assertThat(observation.chunkOneManagedAfterFlush()).containsExactly(true, true);
        assertThat(observation.chunkOneAfterClear()).hasSize(2);
        assertSnapshotMatches(observation.chunkOneAfterClear().get(0), commands.get(0), commands.get(0).businessKey(), false);
        assertSnapshotMatches(observation.chunkOneAfterClear().get(1), commands.get(1), commands.get(1).businessKey(), false);
        assertThat(observation.chunkTwoBeforeFailure()).hasSize(2);
        assertSnapshotMatches(observation.chunkTwoBeforeFailure().get(0), commands.get(2), commands.get(0).businessKey(), true);
        assertSnapshotMatches(observation.chunkTwoBeforeFailure().get(1), commands.get(3), commands.get(3).businessKey(), true);
        assertThat(observation.dirtyBusinessKeyBefore()).isEqualTo(commands.get(2).businessKey());
        assertThat(observation.dirtyBusinessKeyAfter()).isEqualTo(commands.get(0).businessKey());
        assertThat(observation.dirtyBusinessKeyBefore()).isNotEqualTo(observation.dirtyBusinessKeyAfter());
        assertThat(observation.failurePhase()).isEqualTo(FailurePhase.SECOND_CHUNK_EXPLICIT_FLUSH_STARTED);
        assertThat(observation.ids()).hasSize(4).doesNotContainNull().doesNotHaveDuplicates();
        assertThat(observation.processedCount()).isEqualTo(4);
        assertThat(observation.chunkCount()).isEqualTo(2);
        assertThat(observation.chunkSize()).isEqualTo(2);
    }

    private void assertCommittedChunkObservation(
            CommittedChunkObservation observation,
            List<BenchmarkRecordCommand> commands
    ) {
        assertThat(observation.managedAfterPersist()).containsExactly(true, true);
        assertThat(observation.managedAfterFlush()).containsExactly(true, true);
        assertThat(observation.afterClear()).hasSize(2);
        assertSnapshotMatches(observation.afterClear().get(0), commands.get(0), commands.get(0).businessKey(), false);
        assertSnapshotMatches(observation.afterClear().get(1), commands.get(1), commands.get(1).businessKey(), false);
        assertThat(observation.ids()).doesNotContainNull().doesNotHaveDuplicates();
    }

    private void assertSnapshotMatches(
            EntitySnapshot snapshot,
            BenchmarkRecordCommand command,
            String expectedBusinessKey,
            boolean expectedManaged
    ) {
        assertThat(snapshot.managed()).isEqualTo(expectedManaged);
        assertThat(snapshot.id()).isNotNull();
        assertThat(snapshot.businessKey()).isEqualTo(expectedBusinessKey);
        assertThat(snapshot.name()).isEqualTo(command.name());
        assertThat(snapshot.numericValue()).isEqualByComparingTo(command.numericValue());
        assertThat(snapshot.occurredOn()).isEqualTo(command.occurredOn());
        assertThat(snapshot.createdAt()).isEqualTo(CREATED_AT);
    }

    private void assertRowMatches(
            RowSnapshot row,
            BenchmarkRecordCommand command,
            Long expectedId
    ) {
        assertThat(row.managed()).isTrue();
        assertThat(row.id()).isEqualTo(expectedId);
        assertThat(row.businessKey()).isEqualTo(command.businessKey());
        assertThat(row.name()).isEqualTo(command.name());
        assertThat(row.numericValue()).isEqualByComparingTo(command.numericValue());
        assertThat(row.occurredOn()).isEqualTo(command.occurredOn());
        assertThat(row.createdAt()).isEqualTo(CREATED_AT);
    }

    private ConstraintIdentity expectedConstraintIdentity(RuntimeException exception) {
        Throwable current = exception;
        while (current != null) {
            if (current instanceof ConstraintViolationException constraintViolation) {
                return new ConstraintIdentity(
                        exception.getClass().getName(),
                        constraintViolation.getClass().getName(),
                        constraintViolation.getConstraintName(),
                        constraintViolation.getSQLException().getSQLState()
                );
            }
            current = current.getCause();
        }
        throw new AssertionError("constraint violation cause must be present", exception);
    }

    private List<Boolean> contains(BenchmarkRecord... entities) {
        return java.util.Arrays.stream(entities)
                .map(entityManager::contains)
                .toList();
    }

    private List<EntitySnapshot> snapshots(BenchmarkRecord... entities) {
        return java.util.Arrays.stream(entities)
                .map(entity -> new EntitySnapshot(
                        entityManager.contains(entity),
                        entity.getId(),
                        entity.getBusinessKey(),
                        entity.getName(),
                        entity.getNumericValue(),
                        entity.getOccurredOn(),
                        entity.getCreatedAt()
                ))
                .toList();
    }

    private RowSnapshot rowSnapshot(BenchmarkRecord row) {
        return new RowSnapshot(
                entityManager.contains(row),
                row.getId(),
                row.getBusinessKey(),
                row.getName(),
                row.getNumericValue(),
                row.getOccurredOn(),
                row.getCreatedAt()
        );
    }

    private long countById(Long id) {
        Long count = jdbcTemplate().queryForObject(
                "SELECT count(*) FROM benchmark_record WHERE id = ?",
                Long.class,
                id
        );
        return Objects.requireNonNull(count, "row count must not be null");
    }

    private enum FailurePhase {
        NOT_STARTED,
        SECOND_CHUNK_EXPLICIT_FLUSH_STARTED,
        UNEXPECTEDLY_COMPLETED
    }

    private record EntitySnapshot(
            boolean managed,
            Long id,
            String businessKey,
            String name,
            BigDecimal numericValue,
            LocalDate occurredOn,
            Instant createdAt
    ) {
    }

    private record FailureObservation(
            String scenario,
            List<Boolean> chunkOneManagedAfterPersist,
            List<Boolean> chunkOneManagedAfterFlush,
            List<EntitySnapshot> chunkOneAfterClear,
            List<EntitySnapshot> chunkTwoBeforeFailure,
            String dirtyBusinessKeyBefore,
            String dirtyBusinessKeyAfter,
            FailurePhase failurePhase,
            int processedCount,
            int chunkCount,
            int chunkSize
    ) {

        private FailureObservation {
            chunkOneManagedAfterPersist = List.copyOf(chunkOneManagedAfterPersist);
            chunkOneManagedAfterFlush = List.copyOf(chunkOneManagedAfterFlush);
            chunkOneAfterClear = List.copyOf(chunkOneAfterClear);
            chunkTwoBeforeFailure = List.copyOf(chunkTwoBeforeFailure);
        }

        private List<Long> ids() {
            return Stream.concat(chunkOneAfterClear.stream(), chunkTwoBeforeFailure.stream())
                    .map(EntitySnapshot::id)
                    .toList();
        }

        private List<Long> chunkTwoIds() {
            return chunkTwoBeforeFailure.stream().map(EntitySnapshot::id).toList();
        }
    }

    private record CommittedChunkObservation(
            List<Boolean> managedAfterPersist,
            List<Boolean> managedAfterFlush,
            List<EntitySnapshot> afterClear
    ) {

        private CommittedChunkObservation {
            managedAfterPersist = List.copyOf(managedAfterPersist);
            managedAfterFlush = List.copyOf(managedAfterFlush);
            afterClear = List.copyOf(afterClear);
        }

        private List<Long> ids() {
            return afterClear.stream().map(EntitySnapshot::id).toList();
        }
    }

    private record ConstraintIdentity(
            String topLevelException,
            String constraintException,
            String constraintName,
            String sqlState
    ) {
    }

    private record RowSnapshot(
            boolean managed,
            Long id,
            String businessKey,
            String name,
            BigDecimal numericValue,
            LocalDate occurredOn,
            Instant createdAt
    ) {
    }

    private record ReadObservation(List<RowSnapshot> committedRows, List<Long> failedRowCounts) {

        private ReadObservation {
            committedRows = List.copyOf(committedRows);
            failedRowCounts = List.copyOf(failedRowCounts);
        }
    }

    private record CleanupObservation(int capturedIdCount, int deletedRowCount, long remainingRowCount) {
    }
}
