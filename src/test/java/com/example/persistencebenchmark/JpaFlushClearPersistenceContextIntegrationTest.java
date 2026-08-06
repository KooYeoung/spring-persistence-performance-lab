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
class JpaFlushClearPersistenceContextIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    private static final Instant CREATED_AT = Instant.parse("2024-01-01T00:00:00Z");

    @Autowired
    private TransactionTemplate transactionTemplate;

    @PersistenceContext
    private EntityManager entityManager;

    @Test
    void flushKeepsPersistedEntityManagedUntilClearDetachesIt() {
        List<BenchmarkRecordCommand> commands = generatedCommands(1);
        BenchmarkRecordCommand command = commands.get(0);

        PersistenceContextObservation observation = transactionTemplate.execute(status -> {
            BenchmarkRecord entity = BenchmarkRecord.from(command, CREATED_AT);

            entityManager.persist(entity);
            boolean afterPersist = entityManager.contains(entity);

            entityManager.flush();
            boolean afterFlush = entityManager.contains(entity);

            entityManager.clear();
            boolean afterClear = entityManager.contains(entity);

            return new PersistenceContextObservation(afterPersist, afterFlush, afterClear, commands.size());
        });

        assertThat(observation).isNotNull();
        assertThat(observation.afterPersist()).isTrue();
        assertThat(observation.afterFlush()).isTrue();
        assertThat(observation.afterClear()).isFalse();
        assertThat(observation.processedCount()).isEqualTo(1);

        ConsistencyReport report = verifyExpected(commands);
        assertThat(report.hasFailures()).as(report.failureSummary()).isFalse();
    }

    private record PersistenceContextObservation(
            boolean afterPersist,
            boolean afterFlush,
            boolean afterClear,
            int processedCount
    ) {
    }
}
