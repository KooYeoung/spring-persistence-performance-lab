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
import org.springframework.transaction.support.TransactionTemplate;

@EntityScan(basePackageClasses = BenchmarkRecord.class)
class JpaMergeDetachedInstanceIdentityIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    private static final Instant CREATED_AT = Instant.parse("2024-01-01T00:00:00Z");

    @Autowired
    private TransactionTemplate transactionTemplate;

    @PersistenceContext
    private EntityManager entityManager;

    @Test
    void mergeReturnsManagedCopyWhileOriginalRemainsDetached() {
        MergeObservation observation = transactionTemplate.execute(status -> {
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

            BenchmarkRecord merged = entityManager.merge(original);
            boolean originalManagedAfterMerge = entityManager.contains(original);
            boolean mergedManagedAfterMerge = entityManager.contains(merged);

            return new MergeObservation(
                    command.businessKey(),
                    command.name(),
                    command.numericValue(),
                    command.occurredOn(),
                    originalManagedAfterPersist,
                    originalManagedAfterFlush,
                    originalManagedAfterClear,
                    originalManagedAfterMerge,
                    mergedManagedAfterMerge,
                    original == merged,
                    originalIdAfterFlush,
                    original.getId(),
                    merged.getId(),
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
        assertThat(observation.originalBusinessKey()).isEqualTo(observation.mergedBusinessKey());
        assertThat(observation.originalName()).isEqualTo(observation.mergedName());
        assertThat(observation.originalNumericValue()).isEqualByComparingTo(observation.mergedNumericValue());
        assertThat(observation.originalOccurredOn()).isEqualTo(observation.mergedOccurredOn());
        assertThat(observation.originalCreatedAt()).isEqualTo(observation.mergedCreatedAt());
        assertThat(observation.processedCount()).isEqualTo(1);

        List<BenchmarkRecordCommand> commands = List.of(new BenchmarkRecordCommand(
                observation.commandBusinessKey(),
                observation.commandName(),
                observation.commandNumericValue(),
                observation.commandOccurredOn()
        ));
        ConsistencyReport report = verifyExpected(commands);
        assertThat(report.hasFailures()).as(report.failureSummary()).isFalse();
    }

    private record MergeObservation(
            String commandBusinessKey,
            String commandName,
            BigDecimal commandNumericValue,
            LocalDate commandOccurredOn,
            boolean originalManagedAfterPersist,
            boolean originalManagedAfterFlush,
            boolean originalManagedAfterClear,
            boolean originalManagedAfterMerge,
            boolean mergedManagedAfterMerge,
            boolean sameObjectInstance,
            Long originalIdAfterFlush,
            Long originalId,
            Long mergedId,
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
    }
}
