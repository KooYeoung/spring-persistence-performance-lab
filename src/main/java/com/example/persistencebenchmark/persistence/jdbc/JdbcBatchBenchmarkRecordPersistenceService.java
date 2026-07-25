package com.example.persistencebenchmark.persistence.jdbc;

import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.Clock;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Objects;

import com.example.persistencebenchmark.config.BenchmarkPersistenceProperties;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class JdbcBatchBenchmarkRecordPersistenceService {

    private static final String INSERT_SQL = """
            INSERT INTO benchmark_record (business_key, name, numeric_value, occurred_on, created_at)
            VALUES (?, ?, ?, ?, ?)
            """;

    private final JdbcTemplate jdbcTemplate;
    private final BenchmarkPersistenceProperties properties;
    private final Clock clock;

    public JdbcBatchBenchmarkRecordPersistenceService(
            JdbcTemplate jdbcTemplate,
            BenchmarkPersistenceProperties properties,
            Clock clock
    ) {
        this.jdbcTemplate = jdbcTemplate;
        this.properties = properties;
        this.clock = clock;
    }

    @Transactional
    public int saveAll(List<BenchmarkRecordCommand> commands) {
        Objects.requireNonNull(commands, "commands must not be null");
        if (commands.isEmpty()) {
            return 0;
        }

        Instant createdAt = clock.instant();
        int[][] batchResults = jdbcTemplate.batchUpdate(
                INSERT_SQL,
                commands,
                properties.jdbcBatchSize(),
                (preparedStatement, command) -> bind(preparedStatement, command, createdAt)
        );

        return validateBatchResults(batchResults, commands.size());
    }

    private static void bind(
            PreparedStatement preparedStatement,
            BenchmarkRecordCommand command,
            Instant createdAt
    ) throws SQLException {
        preparedStatement.setString(1, command.businessKey());
        preparedStatement.setString(2, command.name());
        preparedStatement.setBigDecimal(3, command.numericValue());
        preparedStatement.setObject(4, command.occurredOn());
        preparedStatement.setObject(5, OffsetDateTime.ofInstant(createdAt, ZoneOffset.UTC));
    }

    private static int validateBatchResults(int[][] batchResults, int expectedCommandCount) {
        if (batchResults == null) {
            throw new IllegalStateException("JDBC batch result must not be null");
        }

        int observedResultCount = 0;
        int affectedRowCount = 0;

        for (int[] batchResult : batchResults) {
            if (batchResult == null) {
                throw new IllegalStateException("JDBC batch result chunk must not be null");
            }

            for (int updateCount : batchResult) {
                observedResultCount++;
                affectedRowCount += validateUpdateCount(updateCount);
            }
        }

        if (observedResultCount != expectedCommandCount) {
            throw new IllegalStateException(
                    "JDBC batch result count " + observedResultCount
                            + " did not match command count " + expectedCommandCount
            );
        }

        return affectedRowCount;
    }

    private static int validateUpdateCount(int updateCount) {
        if (updateCount > 0) {
            return updateCount;
        }
        if (updateCount == Statement.SUCCESS_NO_INFO) {
            return 1;
        }
        if (updateCount == 0) {
            throw new IllegalStateException("JDBC batch update count 0 is unexpected");
        }
        if (updateCount == Statement.EXECUTE_FAILED) {
            throw new IllegalStateException("JDBC batch update reported EXECUTE_FAILED");
        }
        throw new IllegalStateException("Unexpected JDBC batch update count: " + updateCount);
    }
}
