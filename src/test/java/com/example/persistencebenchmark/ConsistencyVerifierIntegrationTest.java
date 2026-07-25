package com.example.persistencebenchmark;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowable;

import java.util.List;

import com.example.persistencebenchmark.consistency.ConsistencyReport;
import com.example.persistencebenchmark.consistency.ConsistencyVerificationException;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

class ConsistencyVerifierIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    @Autowired
    private JpaBenchmarkRecordPersistenceService persistenceService;

    @Test
    void checksumMismatchFailsEvenWhenRowCountAndBusinessKeysMatch() {
        List<BenchmarkRecordCommand> commands = generatedCommands(3);
        persistenceService.saveAll(commands);
        jdbcTemplate().update(
                "UPDATE benchmark_record SET name = ? WHERE business_key = ?",
                "Changed Synthetic Record",
                "record-000002"
        );

        Throwable throwable = catchThrowable(() -> verifyExpected(commands));

        assertThat(throwable).isInstanceOf(ConsistencyVerificationException.class);
        ConsistencyVerificationException exception = (ConsistencyVerificationException) throwable;
        ConsistencyReport report = exception.report();
        assertThat(report.rowCount()).isEqualTo(commands.size());
        assertThat(report.actualBusinessKeys()).isEqualTo(businessKeysOf(commands));
        assertThat(report.expectedChecksum()).isNotEqualTo(report.actualChecksum());
        assertThat(report.hasFailures()).isTrue();
    }
}
