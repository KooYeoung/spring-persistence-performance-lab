package com.example.persistencebenchmark;

import static org.assertj.core.api.Assertions.assertThat;

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
import org.springframework.transaction.support.TransactionTemplate;

@EntityScan(basePackageClasses = BenchmarkRecord.class)
class JpaClearFindInstanceIdentityIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    private static final Instant CREATED_AT = Instant.parse("2024-01-01T00:00:00Z");

    @Autowired
    private TransactionTemplate transactionTemplate;

    @PersistenceContext
    private EntityManager entityManager;

    @Test
    void clearKeepsOriginalDetachedAndFindReturnsDifferentManagedInstanceForSameRow() {
        List<BenchmarkRecordCommand> commands = generatedCommands(1);
        BenchmarkRecordCommand command = commands.get(0);

        ClearFindObservation observation = transactionTemplate.execute(status -> {
            BenchmarkRecord original = BenchmarkRecord.from(command, CREATED_AT);

            entityManager.persist(original);
            boolean originalManagedAfterPersist = entityManager.contains(original);

            entityManager.flush();

            Long originalId = original.getId();
            boolean originalManagedAfterFlush = entityManager.contains(original);

            entityManager.clear();
            boolean originalManagedAfterClear = entityManager.contains(original);

            BenchmarkRecord reloaded = entityManager.find(BenchmarkRecord.class, originalId);
            boolean reloadedPresent = reloaded != null;
            boolean originalManagedAfterFind = entityManager.contains(original);
            boolean reloadedManagedAfterFind = reloadedPresent && entityManager.contains(reloaded);

            return new ClearFindObservation(
                    originalManagedAfterPersist,
                    originalManagedAfterFlush,
                    originalManagedAfterClear,
                    originalManagedAfterFind,
                    reloadedPresent,
                    reloadedManagedAfterFind,
                    original == reloaded,
                    originalId,
                    reloadedPresent ? reloaded.getId() : null,
                    sameStoredFields(original, reloaded),
                    commands.size()
            );
        });

        assertThat(observation).isNotNull();
        assertThat(observation.originalId()).isNotNull();
        assertThat(observation.originalManagedAfterPersist()).isTrue();
        assertThat(observation.originalManagedAfterFlush()).isTrue();
        assertThat(observation.originalManagedAfterClear()).isFalse();
        assertThat(observation.originalManagedAfterFind()).isFalse();
        assertThat(observation.reloadedPresent()).isTrue();
        assertThat(observation.reloadedManagedAfterFind()).isTrue();
        assertThat(observation.sameObjectInstance()).isFalse();
        assertThat(observation.reloadedId()).isEqualTo(observation.originalId());
        assertThat(observation.sameStoredFields()).isTrue();
        assertThat(observation.processedCount()).isEqualTo(1);

        ConsistencyReport report = verifyExpected(commands);
        assertThat(report.hasFailures()).as(report.failureSummary()).isFalse();
    }

    private static boolean sameStoredFields(BenchmarkRecord left, BenchmarkRecord right) {
        if (left == null || right == null) {
            return false;
        }

        return Objects.equals(left.getBusinessKey(), right.getBusinessKey())
                && Objects.equals(left.getName(), right.getName())
                && sameNumericValue(left.getNumericValue(), right.getNumericValue())
                && Objects.equals(left.getOccurredOn(), right.getOccurredOn())
                && Objects.equals(left.getCreatedAt(), right.getCreatedAt());
    }

    private static boolean sameNumericValue(BigDecimal left, BigDecimal right) {
        if (left == null || right == null) {
            return left == right;
        }
        return left.compareTo(right) == 0;
    }

    private record ClearFindObservation(
            boolean originalManagedAfterPersist,
            boolean originalManagedAfterFlush,
            boolean originalManagedAfterClear,
            boolean originalManagedAfterFind,
            boolean reloadedPresent,
            boolean reloadedManagedAfterFind,
            boolean sameObjectInstance,
            Long originalId,
            Long reloadedId,
            boolean sameStoredFields,
            int processedCount
    ) {
    }
}
