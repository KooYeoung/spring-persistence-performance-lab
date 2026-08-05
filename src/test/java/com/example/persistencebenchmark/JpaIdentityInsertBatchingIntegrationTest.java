package com.example.persistencebenchmark;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.regex.MatchResult;
import java.util.regex.Pattern;

import com.example.persistencebenchmark.consistency.ConsistencyReport;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService;
import jakarta.persistence.EntityManagerFactory;
import org.hibernate.engine.spi.SessionFactoryImplementor;
import org.hibernate.stat.Statistics;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.test.context.TestPropertySource;

@ExtendWith(OutputCaptureExtension.class)
@TestPropertySource(properties = {
        "spring.jpa.properties.hibernate.jdbc.batch_size=5",
        "spring.jpa.properties.hibernate.generate_statistics=true",
        "logging.level.org.hibernate.SQL=DEBUG",
        "logging.level.org.hibernate.orm.jdbc.batch=TRACE",
        "logging.level.org.hibernate.engine.internal.StatisticalLoggingSessionEventListener=INFO"
})
class JpaIdentityInsertBatchingIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    private static final Pattern JDBC_BATCH_METRIC =
            Pattern.compile("spent executing (\\d+) JDBC batches");

    @Autowired
    private EntityManagerFactory entityManagerFactory;

    @Autowired
    private JpaBenchmarkRecordPersistenceService persistenceService;

    @Test
    void identityInsertsDoNotExecuteJdbcBatchesEvenWhenBatchSizeIsConfigured(CapturedOutput output) {
        SessionFactoryImplementor sessionFactory = entityManagerFactory.unwrap(SessionFactoryImplementor.class);
        Statistics statistics = sessionFactory.getStatistics();

        assertThat(sessionFactory.getSessionFactoryOptions().getJdbcBatchSize()).isEqualTo(5);
        assertThat(statistics.isStatisticsEnabled()).isTrue();

        List<BenchmarkRecordCommand> commands = generatedCommands(5);
        statistics.clear();
        String outputBeforeSave = output.getAll();

        int savedCount = persistenceService.saveAll(commands);

        String saveOutput = output.getAll().substring(outputBeforeSave.length());
        List<Long> jdbcBatchExecutions = jdbcBatchExecutions(saveOutput);

        assertThat(savedCount).isEqualTo(5);
        assertThat(statistics.getEntityInsertCount()).isEqualTo(5);
        assertThat(statistics.getPrepareStatementCount()).isPositive();
        assertThat(jdbcBatchExecutions)
                .as("Hibernate session metrics for the save segment must expose JDBC batch execution count")
                .isNotEmpty()
                .allSatisfy(batchCount -> assertThat(batchCount).isZero());

        ConsistencyReport report = verifyExpected(commands);
        assertThat(report.hasFailures()).as(report.failureSummary()).isFalse();
    }

    private static List<Long> jdbcBatchExecutions(String output) {
        return JDBC_BATCH_METRIC.matcher(output)
                .results()
                .map(MatchResult::group)
                .map(JpaIdentityInsertBatchingIntegrationTest::parseJdbcBatchExecutionCount)
                .toList();
    }

    private static long parseJdbcBatchExecutionCount(String metricLine) {
        return Long.parseLong(JDBC_BATCH_METRIC.matcher(metricLine).replaceFirst("$1"));
    }
}
