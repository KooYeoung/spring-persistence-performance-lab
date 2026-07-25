package com.example.persistencebenchmark;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;

import com.example.persistencebenchmark.consistency.ConsistencyReport;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import com.example.persistencebenchmark.persistence.jdbc.JdbcBatchBenchmarkRecordPersistenceService;
import com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

class JpaJdbcCrossConsistencyIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    @Autowired
    private JpaBenchmarkRecordPersistenceService jpaPersistenceService;

    @Autowired
    private JdbcBatchBenchmarkRecordPersistenceService jdbcPersistenceService;

    @Test
    void jpaAndJdbcProduceMatchingRowsKeysAndChecksumFromSameCommands() {
        List<BenchmarkRecordCommand> commands = generatedCommands(7);

        int jpaSavedCount = jpaPersistenceService.saveAll(commands);
        ConsistencyReport jpaReport = verifyExpected(commands);

        resetRecords();

        int jdbcSavedCount = jdbcPersistenceService.saveAll(commands);
        ConsistencyReport jdbcReport = verifyExpected(commands);

        assertThat(jpaSavedCount).isEqualTo(commands.size());
        assertThat(jdbcSavedCount).isEqualTo(commands.size());
        assertThat(jpaReport.rowCount()).isEqualTo(jdbcReport.rowCount());
        assertThat(jpaReport.actualBusinessKeys()).isEqualTo(jdbcReport.actualBusinessKeys());
        assertThat(jpaReport.checksum()).isEqualTo(jdbcReport.checksum());
    }
}
