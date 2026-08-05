package com.example.persistencebenchmark;

import static org.assertj.core.api.Assertions.assertThat;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Objects;
import java.util.regex.Pattern;

import com.example.persistencebenchmark.domain.BenchmarkRecord;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EntityManager;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.PersistenceContext;
import jakarta.persistence.SequenceGenerator;
import jakarta.persistence.Table;
import jakarta.persistence.UniqueConstraint;
import javax.sql.DataSource;
import org.hibernate.engine.spi.SessionFactoryImplementor;
import org.hibernate.stat.Statistics;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.domain.EntityScan;
import org.springframework.boot.autoconfigure.flyway.FlywayMigrationStrategy;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.context.ApplicationContextInitializer;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.ContextConfiguration;
import org.springframework.test.context.TestPropertySource;
import org.springframework.transaction.support.TransactionTemplate;

@ExtendWith(OutputCaptureExtension.class)
@ContextConfiguration(initializers = JpaSequenceInsertBatchingIntegrationTest.SequenceSchemaInitializer.class)
@Import(JpaSequenceInsertBatchingIntegrationTest.SequenceEntityScanConfiguration.class)
@TestPropertySource(properties = {
        "spring.jpa.hibernate.ddl-auto=validate",
        "spring.jpa.properties.hibernate.jdbc.batch_size=5",
        "spring.jpa.properties.hibernate.generate_statistics=true",
        "logging.level.org.hibernate.SQL=DEBUG",
        "logging.level.org.hibernate.orm.jdbc.batch=TRACE",
        "logging.level.org.hibernate.engine.internal.StatisticalLoggingSessionEventListener=INFO"
})
class JpaSequenceInsertBatchingIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    private static final Instant CREATED_AT = Instant.parse("2024-01-01T00:00:00Z");
    private static final Pattern JDBC_BATCH_METRIC =
            Pattern.compile("spent executing (\\d+) JDBC batches");

    @Autowired
    private jakarta.persistence.EntityManagerFactory entityManagerFactory;

    @Autowired
    private TransactionTemplate transactionTemplate;

    @PersistenceContext
    private EntityManager entityManager;

    @BeforeEach
    void resetSequenceBatchRecordTable() {
        jdbcTemplate().execute("TRUNCATE TABLE sequence_batch_record RESTART IDENTITY");
        jdbcTemplate().execute("ALTER SEQUENCE sequence_batch_record_seq RESTART WITH 1");
    }

    @Test
    void sequenceInsertsExecuteJdbcBatchesWhenBatchSizeIsConfigured(CapturedOutput output) {
        SessionFactoryImplementor sessionFactory = entityManagerFactory.unwrap(SessionFactoryImplementor.class);
        Statistics statistics = sessionFactory.getStatistics();

        assertThat(sessionFactory.getSessionFactoryOptions().getJdbcBatchSize()).isEqualTo(5);
        assertThat(statistics.isStatisticsEnabled()).isTrue();

        List<BenchmarkRecordCommand> commands = generatedCommands(5);
        statistics.clear();
        String outputBeforeSave = output.getAll();

        int savedCount = transactionTemplate.execute(status -> {
            commands.stream()
                    .map(command -> SequenceBatchRecord.from(command, CREATED_AT))
                    .forEach(entityManager::persist);
            entityManager.flush();
            return commands.size();
        });

        String saveOutput = output.getAll().substring(outputBeforeSave.length());
        List<Long> jdbcBatchExecutions = jdbcBatchExecutions(saveOutput);

        assertThat(savedCount).isEqualTo(5);
        assertThat(statistics.getEntityInsertCount()).isEqualTo(5);
        assertThat(statistics.getPrepareStatementCount()).isPositive();
        assertThat(jdbcBatchExecutions)
                .as("Hibernate session metrics for the save segment must expose JDBC batch execution count")
                .isNotEmpty()
                .allSatisfy(batchCount -> assertThat(batchCount).isPositive());

        assertThat(rowCount()).isEqualTo(5);
        assertThat(distinctBusinessKeyCount()).isEqualTo(5);
        assertThat(actualRows()).containsExactlyElementsOf(expectedRows(commands));
    }

    private long rowCount() {
        Long count = jdbcTemplate().queryForObject("SELECT count(*) FROM sequence_batch_record", Long.class);
        return Objects.requireNonNull(count, "row count must not be null");
    }

    private long distinctBusinessKeyCount() {
        Long count = jdbcTemplate().queryForObject(
                "SELECT count(DISTINCT business_key) FROM sequence_batch_record",
                Long.class
        );
        return Objects.requireNonNull(count, "distinct business key count must not be null");
    }

    private List<SequenceRecordSnapshot> actualRows() {
        return jdbcTemplate().query(
                """
                SELECT business_key, name, numeric_value, occurred_on
                FROM sequence_batch_record
                ORDER BY business_key
                """,
                (rs, rowNum) -> new SequenceRecordSnapshot(
                        rs.getString("business_key"),
                        rs.getString("name"),
                        rs.getBigDecimal("numeric_value"),
                        rs.getDate("occurred_on").toLocalDate()
                )
        );
    }

    private static List<SequenceRecordSnapshot> expectedRows(List<BenchmarkRecordCommand> commands) {
        return commands.stream()
                .map(command -> new SequenceRecordSnapshot(
                        command.businessKey(),
                        command.name(),
                        command.numericValue(),
                        command.occurredOn()
                ))
                .toList();
    }

    private static List<Long> jdbcBatchExecutions(String output) {
        return JDBC_BATCH_METRIC.matcher(output)
                .results()
                .map(result -> Long.parseLong(result.group(1)))
                .toList();
    }

    @TestConfiguration(proxyBeanMethods = false)
    @EntityScan(basePackageClasses = { BenchmarkRecord.class, JpaSequenceInsertBatchingIntegrationTest.SequenceBatchRecord.class })
    static class SequenceEntityScanConfiguration {
    }

    static class SequenceSchemaInitializer
            implements ApplicationContextInitializer<ConfigurableApplicationContext> {

        @Override
        public void initialize(ConfigurableApplicationContext applicationContext) {
            applicationContext.getBeanFactory().registerSingleton(
                    "sequenceSchemaFlywayMigrationStrategy",
                    (FlywayMigrationStrategy) flyway -> {
                        flyway.migrate();
                        createSequenceBatchSchema(flyway.getConfiguration().getDataSource());
                    }
            );
        }

        private static void createSequenceBatchSchema(DataSource dataSource) {
            try (Connection connection = dataSource.getConnection();
                    Statement statement = connection.createStatement()) {
                for (String sql : schemaSql()) {
                    statement.execute(sql);
                }
            } catch (SQLException exception) {
                throw new IllegalStateException("Failed to create sequence batch test schema", exception);
            }
        }

        private static List<String> schemaSql() {
            return List.of(
                    """
                    CREATE SEQUENCE IF NOT EXISTS sequence_batch_record_seq
                    START WITH 1
                    INCREMENT BY 1
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS sequence_batch_record (
                        id BIGINT NOT NULL,
                        business_key VARCHAR(64) NOT NULL,
                        name VARCHAR(100) NOT NULL,
                        numeric_value NUMERIC(19, 4) NOT NULL,
                        occurred_on DATE NOT NULL,
                        created_at TIMESTAMP WITH TIME ZONE NOT NULL,
                        CONSTRAINT pk_sequence_batch_record PRIMARY KEY (id),
                        CONSTRAINT uk_sequence_batch_record_business_key UNIQUE (business_key)
                    )
                    """,
                    "ALTER SEQUENCE sequence_batch_record_seq OWNED BY sequence_batch_record.id"
            );
        }
    }

    @Entity
    @Table(
            name = "sequence_batch_record",
            uniqueConstraints = @UniqueConstraint(
                    name = "uk_sequence_batch_record_business_key",
                    columnNames = "business_key"
            )
    )
    static class SequenceBatchRecord {

        @Id
        @GeneratedValue(strategy = GenerationType.SEQUENCE, generator = "sequence_batch_record_seq_generator")
        @SequenceGenerator(
                name = "sequence_batch_record_seq_generator",
                sequenceName = "sequence_batch_record_seq",
                allocationSize = 1
        )
        private Long id;

        @Column(name = "business_key", nullable = false, length = 64, unique = true)
        private String businessKey;

        @Column(name = "name", nullable = false, length = 100)
        private String name;

        @Column(name = "numeric_value", nullable = false, precision = 19, scale = 4)
        private BigDecimal numericValue;

        @Column(name = "occurred_on", nullable = false)
        private LocalDate occurredOn;

        @Column(name = "created_at", nullable = false)
        private Instant createdAt;

        protected SequenceBatchRecord() {
        }

        private SequenceBatchRecord(
                String businessKey,
                String name,
                BigDecimal numericValue,
                LocalDate occurredOn,
                Instant createdAt
        ) {
            this.businessKey = Objects.requireNonNull(businessKey, "businessKey must not be null");
            this.name = Objects.requireNonNull(name, "name must not be null");
            this.numericValue = Objects.requireNonNull(numericValue, "numericValue must not be null");
            this.occurredOn = Objects.requireNonNull(occurredOn, "occurredOn must not be null");
            this.createdAt = Objects.requireNonNull(createdAt, "createdAt must not be null");
        }

        static SequenceBatchRecord from(BenchmarkRecordCommand command, Instant createdAt) {
            return new SequenceBatchRecord(
                    command.businessKey(),
                    command.name(),
                    command.numericValue(),
                    command.occurredOn(),
                    createdAt
            );
        }
    }

    private record SequenceRecordSnapshot(
            String businessKey,
            String name,
            BigDecimal numericValue,
            LocalDate occurredOn
    ) {
    }
}
