package com.example.persistencebenchmark;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.List;

import com.example.persistencebenchmark.consistency.ConsistencyReport;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import com.example.persistencebenchmark.persistence.jdbc.JdbcBatchBenchmarkRecordPersistenceService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DataAccessException;

class JdbcBatchBenchmarkRecordPersistenceServiceIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    @Autowired
    private JdbcBatchBenchmarkRecordPersistenceService persistenceService;

    @Test
    void emptyInputReturnsZeroAndLeavesDatabaseEmpty() {
        int savedCount = persistenceService.saveAll(List.of());

        ConsistencyReport report = verifyExpected(List.of());

        assertThat(savedCount).isZero();
        assertThat(report.rowCount()).isZero();
        assertThat(report.actualBusinessKeys()).isEmpty();
        assertThat(report.checksum()).matches("[0-9a-f]{64}");
    }

    @Test
    void oneRowIsSavedAndVerified() {
        List<BenchmarkRecordCommand> commands = generatedCommands(1);

        int savedCount = persistenceService.saveAll(commands);

        ConsistencyReport report = verifyExpected(commands);
        assertThat(savedCount).isEqualTo(1);
        assertThat(report.rowCount()).isEqualTo(1);
        assertThat(report.actualBusinessKeys()).containsExactly("record-000001");
        assertThat(report.checksum()).matches("[0-9a-f]{64}");
    }

    @Test
    void smallMultipleRowsAreSavedAndVerified() {
        List<BenchmarkRecordCommand> commands = generatedCommands(5);

        int savedCount = persistenceService.saveAll(commands);

        ConsistencyReport report = verifyExpected(commands);
        assertThat(savedCount).isEqualTo(commands.size());
        assertThat(report.rowCount()).isEqualTo(commands.size());
        assertThat(report.distinctBusinessKeyCount()).isEqualTo(commands.size());
        assertThat(report.actualBusinessKeys()).isEqualTo(businessKeysOf(commands));
        assertThat(report.checksum()).matches("[0-9a-f]{64}");
    }

    @Test
    void countAboveConfiguredBatchBoundaryIsSavedAndVerified() {
        List<BenchmarkRecordCommand> commands = generatedCommands(7);

        int savedCount = persistenceService.saveAll(commands);

        ConsistencyReport report = verifyExpected(commands);
        assertThat(savedCount).isEqualTo(commands.size());
        assertThat(report.rowCount()).isEqualTo(commands.size());
        assertThat(report.actualBusinessKeys()).isEqualTo(businessKeysOf(commands));
    }

    @Test
    void duplicateBusinessKeyRollsBackWholeTransaction() {
        assertThatThrownBy(() -> persistenceService.saveAll(duplicateBusinessKeyCommands()))
                .isInstanceOf(DataAccessException.class);

        ConsistencyReport report = verifyExpected(List.of());
        assertThat(report.rowCount()).isZero();
        assertThat(report.actualBusinessKeys()).isEmpty();
    }
}
