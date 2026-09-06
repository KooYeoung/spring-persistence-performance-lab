package com.example.persistencebenchmark;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertNotSame;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Objects;

import com.example.persistencebenchmark.consistency.ConsistencyReport;
import com.example.persistencebenchmark.domain.BenchmarkRecord;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.domain.EntityScan;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;

@EntityScan(basePackageClasses = BenchmarkRecord.class)
class JpaMergeDetachedPostMergeMutationIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    private static final Instant CREATED_AT = Instant.parse("2024-01-01T00:00:00Z");
    private static final String INITIAL_NAME = "merge-post-call-initial";
    private static final String MERGE_TIME_NAME = "merge-post-call-at-merge";
    private static final String POST_MERGE_NAME = "merge-post-call-after-merge";

    @Autowired
    private TransactionTemplate transactionTemplate;

    @PersistenceContext
    private EntityManager entityManager;

    @Test
    void changingDetachedOriginalAfterMergeDoesNotChangeManagedCopyOrCommittedRow() {
        assertThat(List.of(INITIAL_NAME, MERGE_TIME_NAME, POST_MERGE_NAME)).doesNotHaveDuplicates();

        BenchmarkRecordCommand seed = generatedCommands(1).get(0);
        BenchmarkRecordCommand initialCommand = new BenchmarkRecordCommand(
                seed.businessKey(),
                INITIAL_NAME,
                seed.numericValue(),
                seed.occurredOn()
        );

        BenchmarkRecord detachedOriginal = BenchmarkRecord.from(initialCommand, CREATED_AT);
        PersistObservation persistObservation = transactionTemplate.execute(status -> {
            entityManager.persist(detachedOriginal);
            boolean managedAfterPersist = entityManager.contains(detachedOriginal);

            entityManager.flush();
            Long persistedId = detachedOriginal.getId();
            boolean managedAfterFlush = entityManager.contains(detachedOriginal);
            return new PersistObservation(
                    persistedId,
                    managedAfterPersist,
                    managedAfterFlush,
                    detachedOriginal.getName()
            );
        });
        Long persistedId = persistObservation == null ? null : persistObservation.persistedId();

        try {
            assertThat(detachedOriginal).isNotNull();
            assertThat(persistObservation).isNotNull();
            assertThat(persistedId).isNotNull();
            assertThat(persistObservation.managedAfterPersist()).isTrue();
            assertThat(persistObservation.managedAfterFlush()).isTrue();
            assertThat(persistObservation.nameAfterFlush()).isEqualTo(INITIAL_NAME);

            ReflectionTestUtils.setField(detachedOriginal, "name", MERGE_TIME_NAME);
            assertThat(detachedOriginal.getName()).isEqualTo(MERGE_TIME_NAME);

            MergeObservation mergeObservation = transactionTemplate.execute(status -> {
                boolean originalManagedBeforeMerge = entityManager.contains(detachedOriginal);

                BenchmarkRecord managedCopy = entityManager.merge(detachedOriginal);
                assertNotSame(detachedOriginal, managedCopy);

                boolean originalManagedAfterMerge = entityManager.contains(detachedOriginal);
                boolean managedCopyManagedAfterMerge = entityManager.contains(managedCopy);
                Long originalId = detachedOriginal.getId();
                Long managedCopyId = managedCopy.getId();
                String originalNameAtMerge = detachedOriginal.getName();
                String managedCopyNameAtMerge = managedCopy.getName();

                ReflectionTestUtils.setField(detachedOriginal, "name", POST_MERGE_NAME);

                return new MergeObservation(
                        originalManagedBeforeMerge,
                        originalManagedAfterMerge,
                        managedCopyManagedAfterMerge,
                        detachedOriginal == managedCopy,
                        originalId,
                        managedCopyId,
                        originalNameAtMerge,
                        managedCopyNameAtMerge,
                        detachedOriginal.getName(),
                        managedCopy.getName(),
                        entityManager.contains(detachedOriginal),
                        entityManager.contains(managedCopy)
                );
            });

            assertThat(mergeObservation).isNotNull();
            assertThat(mergeObservation.originalManagedBeforeMerge()).isFalse();
            assertThat(mergeObservation.originalManagedAfterMerge()).isFalse();
            assertThat(mergeObservation.managedCopyManagedAfterMerge()).isTrue();
            assertThat(mergeObservation.sameObjectInstance()).isFalse();
            assertThat(mergeObservation.originalId()).isEqualTo(persistedId);
            assertThat(mergeObservation.managedCopyId()).isEqualTo(persistedId);
            assertThat(mergeObservation.originalNameAtMerge()).isEqualTo(MERGE_TIME_NAME);
            assertThat(mergeObservation.managedCopyNameAtMerge()).isEqualTo(MERGE_TIME_NAME);
            assertThat(mergeObservation.originalNameAfterPostMergeChange()).isEqualTo(POST_MERGE_NAME);
            assertThat(mergeObservation.managedCopyNameAfterPostMergeChange()).isEqualTo(MERGE_TIME_NAME);
            assertThat(mergeObservation.originalManagedAfterPostMergeChange()).isFalse();
            assertThat(mergeObservation.managedCopyManagedAfterPostMergeChange()).isTrue();

            RowObservation rowObservation = transactionTemplate.execute(status -> {
                BenchmarkRecord committed = entityManager.find(BenchmarkRecord.class, persistedId);
                Long rowCount = jdbcTemplate().queryForObject(
                        "SELECT count(*) FROM benchmark_record WHERE id = ?",
                        Long.class,
                        persistedId
                );
                assertThat(committed).isNotNull();

                return new RowObservation(
                        entityManager.contains(committed),
                        committed.getId(),
                        committed.getBusinessKey(),
                        committed.getName(),
                        committed.getNumericValue(),
                        committed.getOccurredOn(),
                        committed.getCreatedAt(),
                        Objects.requireNonNull(rowCount, "row count must not be null")
                );
            });

            assertThat(rowObservation).isNotNull();
            assertThat(rowObservation.managed()).isTrue();
            assertThat(rowObservation.id()).isEqualTo(persistedId);
            assertThat(rowObservation.businessKey()).isEqualTo(initialCommand.businessKey());
            assertThat(rowObservation.name()).isEqualTo(MERGE_TIME_NAME);
            assertThat(rowObservation.name()).isNotEqualTo(POST_MERGE_NAME);
            assertThat(rowObservation.numericValue()).isEqualByComparingTo(initialCommand.numericValue());
            assertThat(rowObservation.occurredOn()).isEqualTo(initialCommand.occurredOn());
            assertThat(rowObservation.createdAt()).isEqualTo(CREATED_AT);
            assertThat(rowObservation.rowCount()).isEqualTo(1L);

            BenchmarkRecordCommand expectedCommand = new BenchmarkRecordCommand(
                    initialCommand.businessKey(),
                    MERGE_TIME_NAME,
                    initialCommand.numericValue(),
                    initialCommand.occurredOn()
            );
            ConsistencyReport report = verifyExpected(List.of(expectedCommand));
            assertThat(report.hasFailures()).as(report.failureSummary()).isFalse();
        } finally {
            if (persistedId != null) {
                transactionTemplate.executeWithoutResult(status ->
                        jdbcTemplate().update("DELETE FROM benchmark_record WHERE id = ?", persistedId)
                );
            }
        }
    }

    private record PersistObservation(
            Long persistedId,
            boolean managedAfterPersist,
            boolean managedAfterFlush,
            String nameAfterFlush
    ) {
    }

    private record MergeObservation(
            boolean originalManagedBeforeMerge,
            boolean originalManagedAfterMerge,
            boolean managedCopyManagedAfterMerge,
            boolean sameObjectInstance,
            Long originalId,
            Long managedCopyId,
            String originalNameAtMerge,
            String managedCopyNameAtMerge,
            String originalNameAfterPostMergeChange,
            String managedCopyNameAfterPostMergeChange,
            boolean originalManagedAfterPostMergeChange,
            boolean managedCopyManagedAfterPostMergeChange
    ) {
    }

    private record RowObservation(
            boolean managed,
            Long id,
            String businessKey,
            String name,
            BigDecimal numericValue,
            LocalDate occurredOn,
            Instant createdAt,
            long rowCount
    ) {
    }
}
