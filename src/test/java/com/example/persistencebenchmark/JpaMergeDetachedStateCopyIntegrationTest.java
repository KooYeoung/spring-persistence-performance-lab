package com.example.persistencebenchmark;

import static org.assertj.core.api.Assertions.assertThat;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;

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
class JpaMergeDetachedStateCopyIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    private static final Instant CREATED_AT = Instant.parse("2024-01-01T00:00:00Z");
    private static final String UPDATED_NAME = "merge-detached-updated";

    @Autowired
    private TransactionTemplate transactionTemplate;

    @PersistenceContext
    private EntityManager entityManager;

    @Test
    void mergeCopiesDetachedNameToManagedReturnValueAndCommittedRow() {
        MergeStateCopyObservation observation = transactionTemplate.execute(status -> {
            List<BenchmarkRecordCommand> commands = generatedCommands(1);
            BenchmarkRecordCommand command = commands.get(0);
            BenchmarkRecord original = BenchmarkRecord.from(command, CREATED_AT);

            entityManager.persist(original);
            boolean originalManagedAfterPersist = entityManager.contains(original);

            entityManager.flush();
            Long originalIdAfterFlush = original.getId();
            boolean originalManagedAfterFlush = entityManager.contains(original);

            entityManager.clear();
            boolean originalManagedAfterClear = entityManager.contains(original);

            ReflectionTestUtils.setField(original, "name", UPDATED_NAME);
            String originalNameAfterDetachedChange = original.getName();

            BenchmarkRecord merged = entityManager.merge(original);
            boolean originalManagedAfterMerge = entityManager.contains(original);
            boolean mergedManagedAfterMerge = entityManager.contains(merged);

            return new MergeStateCopyObservation(
                    commands,
                    originalManagedAfterPersist,
                    originalManagedAfterFlush,
                    originalManagedAfterClear,
                    originalManagedAfterMerge,
                    mergedManagedAfterMerge,
                    original == merged,
                    originalIdAfterFlush,
                    original.getId(),
                    merged.getId(),
                    originalNameAfterDetachedChange,
                    original.getBusinessKey(),
                    merged.getBusinessKey(),
                    original.getName(),
                    merged.getName(),
                    original.getNumericValue(),
                    merged.getNumericValue(),
                    original.getOccurredOn(),
                    merged.getOccurredOn(),
                    original.getCreatedAt(),
                    merged.getCreatedAt(),
                    commands.size()
            );
        });

        assertThat(observation).isNotNull();
        assertThat(observation.commands()).hasSize(1);
        BenchmarkRecordCommand command = observation.commands().get(0);

        assertThat(observation.originalManagedAfterPersist()).isTrue();
        assertThat(observation.originalManagedAfterFlush()).isTrue();
        assertThat(observation.originalManagedAfterClear()).isFalse();
        assertThat(observation.originalManagedAfterMerge()).isFalse();
        assertThat(observation.mergedManagedAfterMerge()).isTrue();
        assertThat(observation.sameObjectInstance()).isFalse();
        assertThat(observation.originalIdAfterFlush()).isNotNull();
        assertThat(observation.originalId()).isNotNull();
        assertThat(observation.mergedId()).isNotNull();
        assertThat(observation.originalId()).isEqualTo(observation.mergedId());
        assertThat(observation.originalIdAfterFlush()).isEqualTo(observation.originalId());
        assertThat(observation.originalNameAfterDetachedChange()).isEqualTo(UPDATED_NAME);
        assertThat(observation.originalBusinessKey()).isEqualTo(command.businessKey());
        assertThat(observation.mergedBusinessKey()).isEqualTo(command.businessKey());
        assertThat(observation.originalName()).isEqualTo(UPDATED_NAME);
        assertThat(observation.mergedName()).isEqualTo(UPDATED_NAME);
        assertThat(observation.originalNumericValue()).isEqualByComparingTo(command.numericValue());
        assertThat(observation.mergedNumericValue()).isEqualByComparingTo(command.numericValue());
        assertThat(observation.originalOccurredOn()).isEqualTo(command.occurredOn());
        assertThat(observation.mergedOccurredOn()).isEqualTo(command.occurredOn());
        assertThat(observation.originalCreatedAt()).isEqualTo(CREATED_AT);
        assertThat(observation.mergedCreatedAt()).isEqualTo(CREATED_AT);
        assertThat(observation.processedCount()).isEqualTo(1);

        List<BenchmarkRecordCommand> expectedCommands = List.of(new BenchmarkRecordCommand(
                command.businessKey(),
                UPDATED_NAME,
                command.numericValue(),
                command.occurredOn()
        ));
        ConsistencyReport report = verifyExpected(expectedCommands);
        assertThat(report.hasFailures()).as(report.failureSummary()).isFalse();
    }

    private record MergeStateCopyObservation(
            List<BenchmarkRecordCommand> commands,
            boolean originalManagedAfterPersist,
            boolean originalManagedAfterFlush,
            boolean originalManagedAfterClear,
            boolean originalManagedAfterMerge,
            boolean mergedManagedAfterMerge,
            boolean sameObjectInstance,
            Long originalIdAfterFlush,
            Long originalId,
            Long mergedId,
            String originalNameAfterDetachedChange,
            String originalBusinessKey,
            String mergedBusinessKey,
            String originalName,
            String mergedName,
            BigDecimal originalNumericValue,
            BigDecimal mergedNumericValue,
            LocalDate originalOccurredOn,
            LocalDate mergedOccurredOn,
            Instant originalCreatedAt,
            Instant mergedCreatedAt,
            int processedCount
    ) {

        private MergeStateCopyObservation {
            commands = List.copyOf(commands);
        }
    }
}
