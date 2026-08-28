package com.example.persistencebenchmark;

import static org.assertj.core.api.Assertions.assertThat;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
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
class JpaFlushClearChunkBoundaryIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    private static final Instant CREATED_AT = Instant.parse("2024-01-01T00:00:00Z");

    @Autowired
    private TransactionTemplate transactionTemplate;

    @PersistenceContext
    private EntityManager entityManager;

    @Test
    void flushKeepsCurrentChunkManagedAndClearDetachesWholeContextBeforeNextChunk() {
        List<BenchmarkRecordCommand> commands = generatedCommands(4);
        List<Long> cleanupIds = new ArrayList<>();

        try {
            ChunkBoundaryObservation observation = transactionTemplate.execute(status -> {
                BenchmarkRecord entityA = BenchmarkRecord.from(commands.get(0), CREATED_AT);
                BenchmarkRecord entityB = BenchmarkRecord.from(commands.get(1), CREATED_AT);
                BenchmarkRecord entityC = BenchmarkRecord.from(commands.get(2), CREATED_AT);
                BenchmarkRecord entityD = BenchmarkRecord.from(commands.get(3), CREATED_AT);

                entityManager.persist(entityA);
                entityManager.persist(entityB);
                List<Boolean> chunkOneAfterPersist = contains(entityA, entityB);

                entityManager.flush();
                List<Boolean> chunkOneAfterFirstFlush = contains(entityA, entityB);
                Long idA = entityA.getId();
                Long idB = entityB.getId();

                entityManager.clear();
                List<Boolean> chunkOneAfterFirstClear = contains(entityA, entityB);

                entityManager.persist(entityC);
                entityManager.persist(entityD);
                List<Boolean> chunkOneDuringSecondChunk = contains(entityA, entityB);
                List<Boolean> chunkTwoAfterPersist = contains(entityC, entityD);

                entityManager.flush();
                List<Boolean> chunkOneAfterSecondFlush = contains(entityA, entityB);
                List<Boolean> chunkTwoAfterSecondFlush = contains(entityC, entityD);
                Long idC = entityC.getId();
                Long idD = entityD.getId();

                entityManager.clear();
                List<Boolean> allAfterSecondClear = contains(entityA, entityB, entityC, entityD);

                return new ChunkBoundaryObservation(
                        chunkOneAfterPersist,
                        chunkOneAfterFirstFlush,
                        chunkOneAfterFirstClear,
                        chunkOneDuringSecondChunk,
                        chunkTwoAfterPersist,
                        chunkOneAfterSecondFlush,
                        chunkTwoAfterSecondFlush,
                        allAfterSecondClear,
                        List.of(idA, idB, idC, idD),
                        commands.size(),
                        2,
                        2
                );
            });

            assertThat(observation).isNotNull();
            cleanupIds.addAll(observation.ids());
            assertThat(observation.chunkOneAfterPersist()).containsExactly(true, true);
            assertThat(observation.chunkOneAfterFirstFlush()).containsExactly(true, true);
            assertThat(observation.chunkOneAfterFirstClear()).containsExactly(false, false);
            assertThat(observation.chunkOneDuringSecondChunk()).containsExactly(false, false);
            assertThat(observation.chunkTwoAfterPersist()).containsExactly(true, true);
            assertThat(observation.chunkOneAfterSecondFlush()).containsExactly(false, false);
            assertThat(observation.chunkTwoAfterSecondFlush()).containsExactly(true, true);
            assertThat(observation.allAfterSecondClear()).containsExactly(false, false, false, false);
            assertThat(observation.ids()).hasSize(4).doesNotContainNull().doesNotHaveDuplicates();
            assertThat(observation.processedCount()).isEqualTo(4);
            assertThat(observation.chunkCount()).isEqualTo(2);
            assertThat(observation.chunkSize()).isEqualTo(2);

            ReadObservation readObservation = transactionTemplate.execute(status -> {
                List<RowSnapshot> rows = observation.ids().stream()
                        .map(id -> {
                            BenchmarkRecord row = entityManager.find(BenchmarkRecord.class, id);
                            assertThat(row).isNotNull();
                            return new RowSnapshot(
                                    entityManager.contains(row),
                                    row.getId(),
                                    row.getBusinessKey(),
                                    row.getName(),
                                    row.getNumericValue(),
                                    row.getOccurredOn(),
                                    row.getCreatedAt()
                            );
                        })
                        .toList();
                return new ReadObservation(rows);
            });

            assertThat(readObservation).isNotNull();
            assertThat(readObservation.rows()).hasSize(4);
            for (int index = 0; index < commands.size(); index++) {
                BenchmarkRecordCommand command = commands.get(index);
                RowSnapshot row = readObservation.rows().get(index);
                assertThat(row.managed()).isTrue();
                assertThat(row.id()).isEqualTo(observation.ids().get(index));
                assertThat(row.businessKey()).isEqualTo(command.businessKey());
                assertThat(row.name()).isEqualTo(command.name());
                assertThat(row.numericValue()).isEqualByComparingTo(command.numericValue());
                assertThat(row.occurredOn()).isEqualTo(command.occurredOn());
                assertThat(row.createdAt()).isEqualTo(CREATED_AT);
            }

            ConsistencyReport report = verifyExpected(commands);
            assertThat(report.rowCount()).isEqualTo(4);
            assertThat(report.hasFailures()).as(report.failureSummary()).isFalse();
        } finally {
            if (!cleanupIds.isEmpty()) {
                List<Long> idsToDelete = List.copyOf(cleanupIds);
                transactionTemplate.executeWithoutResult(status -> idsToDelete.forEach(id ->
                        jdbcTemplate().update("DELETE FROM benchmark_record WHERE id = ?", id)
                ));
            }
        }
    }

    private List<Boolean> contains(BenchmarkRecord... entities) {
        return java.util.Arrays.stream(entities)
                .map(entityManager::contains)
                .toList();
    }

    private record ChunkBoundaryObservation(
            List<Boolean> chunkOneAfterPersist,
            List<Boolean> chunkOneAfterFirstFlush,
            List<Boolean> chunkOneAfterFirstClear,
            List<Boolean> chunkOneDuringSecondChunk,
            List<Boolean> chunkTwoAfterPersist,
            List<Boolean> chunkOneAfterSecondFlush,
            List<Boolean> chunkTwoAfterSecondFlush,
            List<Boolean> allAfterSecondClear,
            List<Long> ids,
            int processedCount,
            int chunkCount,
            int chunkSize
    ) {

        private ChunkBoundaryObservation {
            chunkOneAfterPersist = List.copyOf(chunkOneAfterPersist);
            chunkOneAfterFirstFlush = List.copyOf(chunkOneAfterFirstFlush);
            chunkOneAfterFirstClear = List.copyOf(chunkOneAfterFirstClear);
            chunkOneDuringSecondChunk = List.copyOf(chunkOneDuringSecondChunk);
            chunkTwoAfterPersist = List.copyOf(chunkTwoAfterPersist);
            chunkOneAfterSecondFlush = List.copyOf(chunkOneAfterSecondFlush);
            chunkTwoAfterSecondFlush = List.copyOf(chunkTwoAfterSecondFlush);
            allAfterSecondClear = List.copyOf(allAfterSecondClear);
            ids = List.copyOf(ids);
        }
    }

    private record ReadObservation(List<RowSnapshot> rows) {

        private ReadObservation {
            rows = List.copyOf(rows);
        }
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
}
