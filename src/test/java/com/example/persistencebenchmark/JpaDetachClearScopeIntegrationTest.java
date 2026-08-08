package com.example.persistencebenchmark;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Instant;
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
class JpaDetachClearScopeIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    private static final Instant CREATED_AT = Instant.parse("2024-01-01T00:00:00Z");

    @Autowired
    private TransactionTemplate transactionTemplate;

    @PersistenceContext
    private EntityManager entityManager;

    @Test
    void detachRemovesOnlySelectedEntityUntilClearDetachesRemainingManagedEntity() {
        List<BenchmarkRecordCommand> commands = generatedCommands(2);
        BenchmarkRecordCommand firstCommand = commands.get(0);
        BenchmarkRecordCommand secondCommand = commands.get(1);

        DetachClearObservation observation = transactionTemplate.execute(status -> {
            BenchmarkRecord first = BenchmarkRecord.from(firstCommand, CREATED_AT);
            BenchmarkRecord second = BenchmarkRecord.from(secondCommand, CREATED_AT);

            entityManager.persist(first);
            entityManager.persist(second);
            boolean firstManagedAfterPersist = entityManager.contains(first);
            boolean secondManagedAfterPersist = entityManager.contains(second);

            entityManager.flush();
            boolean firstManagedAfterFlush = entityManager.contains(first);
            boolean secondManagedAfterFlush = entityManager.contains(second);

            entityManager.detach(first);
            boolean firstManagedAfterDetach = entityManager.contains(first);
            boolean secondManagedAfterDetach = entityManager.contains(second);

            entityManager.clear();
            boolean firstManagedAfterClear = entityManager.contains(first);
            boolean secondManagedAfterClear = entityManager.contains(second);

            return new DetachClearObservation(
                    firstManagedAfterPersist,
                    secondManagedAfterPersist,
                    firstManagedAfterFlush,
                    secondManagedAfterFlush,
                    firstManagedAfterDetach,
                    secondManagedAfterDetach,
                    firstManagedAfterClear,
                    secondManagedAfterClear,
                    commands.size()
            );
        });

        assertThat(observation).isNotNull();
        assertThat(observation.firstManagedAfterPersist()).isTrue();
        assertThat(observation.secondManagedAfterPersist()).isTrue();
        assertThat(observation.firstManagedAfterFlush()).isTrue();
        assertThat(observation.secondManagedAfterFlush()).isTrue();
        assertThat(observation.firstManagedAfterDetach()).isFalse();
        assertThat(observation.secondManagedAfterDetach()).isTrue();
        assertThat(observation.firstManagedAfterClear()).isFalse();
        assertThat(observation.secondManagedAfterClear()).isFalse();
        assertThat(observation.processedCount()).isEqualTo(2);

        ConsistencyReport report = verifyExpected(commands);
        assertThat(report.hasFailures()).as(report.failureSummary()).isFalse();
    }

    private record DetachClearObservation(
            boolean firstManagedAfterPersist,
            boolean secondManagedAfterPersist,
            boolean firstManagedAfterFlush,
            boolean secondManagedAfterFlush,
            boolean firstManagedAfterDetach,
            boolean secondManagedAfterDetach,
            boolean firstManagedAfterClear,
            boolean secondManagedAfterClear,
            int processedCount
    ) {
    }
}
