package com.example.persistenceallocation;

import static org.assertj.core.api.Assertions.assertThat;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Objects;
import java.util.function.Function;
import java.util.regex.Pattern;

import com.example.persistencebenchmark.PersistenceBenchmarkApplication;
import com.example.persistencebenchmark.domain.BenchmarkRecord;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommandGenerator;
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
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.context.ApplicationContextInitializer;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ContextConfiguration;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestPropertySource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

@SpringBootTest(classes = PersistenceBenchmarkApplication.class)
@ExtendWith(OutputCaptureExtension.class)
@ContextConfiguration(initializers = JpaSequenceAllocationSizeIntegrationTest.SequenceAllocationSchemaInitializer.class)
@Import(JpaSequenceAllocationSizeIntegrationTest.SequenceAllocationEntityScanConfiguration.class)
@TestPropertySource(properties = {
        "spring.jpa.hibernate.ddl-auto=validate",
        "spring.jpa.properties.hibernate.jdbc.batch_size=5",
        "spring.jpa.properties.hibernate.generate_statistics=true",
        "logging.level.org.hibernate.SQL=DEBUG",
        "logging.level.org.hibernate.orm.jdbc.batch=TRACE",
        "logging.level.org.hibernate.engine.internal.StatisticalLoggingSessionEventListener=INFO"
})
class JpaSequenceAllocationSizeIntegrationTest {

    private static final DockerImageName POSTGRES_IMAGE = DockerImageName.parse("postgres:17.6-alpine");
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>(POSTGRES_IMAGE)
            .withDatabaseName("persistence_lab_test")
            .withUsername("test_user")
            .withPassword("test_password");
    private static final Instant CREATED_AT = Instant.parse("2024-01-01T00:00:00Z");
    private static final String ALLOCATION_ONE_TABLE = "sequence_allocation_one_record";
    private static final String ALLOCATION_ONE_SEQUENCE = "sequence_allocation_one_record_seq";
    private static final String ALLOCATION_FIVE_TABLE = "sequence_allocation_five_record";
    private static final String ALLOCATION_FIVE_SEQUENCE = "sequence_allocation_five_record_seq";
    private static final Pattern JDBC_BATCH_METRIC =
            Pattern.compile("spent executing (\\d+) JDBC batches");

    static {
        POSTGRES.start();
    }

    @Autowired
    private jakarta.persistence.EntityManagerFactory entityManagerFactory;

    @Autowired
    private TransactionTemplate transactionTemplate;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @PersistenceContext
    private EntityManager entityManager;

    @DynamicPropertySource
    static void registerDatabaseProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
        registry.add("lab.persistence.jdbc-batch-size", () -> "3");
    }

    @BeforeEach
    void resetSequenceAllocationTables() {
        jdbcTemplate.execute(
                "TRUNCATE TABLE sequence_allocation_one_record, sequence_allocation_five_record RESTART IDENTITY"
        );
        jdbcTemplate.execute("ALTER SEQUENCE sequence_allocation_one_record_seq RESTART WITH 1");
        jdbcTemplate.execute("ALTER SEQUENCE sequence_allocation_five_record_seq RESTART WITH 1");
    }

    @Test
    void largerAllocationSizeReducesSequenceFetchesWhileJdbcBatchingStillExecutes(CapturedOutput output) {
        SessionFactoryImplementor sessionFactory = entityManagerFactory.unwrap(SessionFactoryImplementor.class);
        Statistics statistics = sessionFactory.getStatistics();

        assertThat(sessionFactory.getSessionFactoryOptions().getJdbcBatchSize()).isEqualTo(5);
        assertThat(statistics.isStatisticsEnabled()).isTrue();

        List<BenchmarkRecordCommand> commands = BenchmarkRecordCommandGenerator.generate(5);

        ObservedSave allocationOne = observeSave(
                output,
                statistics,
                commands,
                command -> AllocationOneRecord.from(command, CREATED_AT),
                ALLOCATION_ONE_SEQUENCE
        );
        ObservedSave allocationFive = observeSave(
                output,
                statistics,
                commands,
                command -> AllocationFiveRecord.from(command, CREATED_AT),
                ALLOCATION_FIVE_SEQUENCE
        );

        assertObservedSave(allocationOne);
        assertObservedSave(allocationFive);
        assertThat(allocationOne.nextvalCount()).isEqualTo(5);
        assertThat(allocationFive.nextvalCount())
                .isPositive()
                .isLessThan(allocationOne.nextvalCount());

        assertRowsMatch(ALLOCATION_ONE_TABLE, commands);
        assertRowsMatch(ALLOCATION_FIVE_TABLE, commands);
    }

    private ObservedSave observeSave(
            CapturedOutput output,
            Statistics statistics,
            List<BenchmarkRecordCommand> commands,
            Function<BenchmarkRecordCommand, Object> entityFactory,
            String sequenceName
    ) {
        statistics.clear();
        String outputBeforeSave = output.getAll();

        int savedCount = transactionTemplate.execute(status -> {
            commands.stream()
                    .map(entityFactory)
                    .forEach(entityManager::persist);
            entityManager.flush();
            return commands.size();
        });

        String saveOutput = output.getAll().substring(outputBeforeSave.length());
        return new ObservedSave(
                savedCount,
                statistics.getEntityInsertCount(),
                statistics.getPrepareStatementCount(),
                nextvalCount(saveOutput, sequenceName),
                jdbcBatchExecutions(saveOutput)
        );
    }

    private static void assertObservedSave(ObservedSave observedSave) {
        assertThat(observedSave.savedCount()).isEqualTo(5);
        assertThat(observedSave.entityInsertCount()).isEqualTo(5);
        assertThat(observedSave.prepareStatementCount()).isPositive();
        assertThat(observedSave.jdbcBatchExecutions())
                .as("Hibernate session metrics for the save segment must expose one JDBC batch execution count")
                .containsExactly(1L);
    }

    private static long nextvalCount(String output, String sequenceName) {
        Pattern pattern = Pattern.compile("select nextval\\('" + Pattern.quote(sequenceName) + "'\\)");
        return pattern.matcher(output).results().count();
    }

    private static List<Long> jdbcBatchExecutions(String output) {
        return JDBC_BATCH_METRIC.matcher(output)
                .results()
                .map(result -> Long.parseLong(result.group(1)))
                .toList();
    }

    private void assertRowsMatch(String tableName, List<BenchmarkRecordCommand> commands) {
        assertThat(rowCount(tableName)).isEqualTo(5);
        assertThat(distinctBusinessKeyCount(tableName)).isEqualTo(5);
        assertThat(actualRows(tableName)).containsExactlyElementsOf(expectedRows(commands));
    }

    private long rowCount(String tableName) {
        Long count = jdbcTemplate.queryForObject("SELECT count(*) FROM " + tableName, Long.class);
        return Objects.requireNonNull(count, "row count must not be null");
    }

    private long distinctBusinessKeyCount(String tableName) {
        Long count = jdbcTemplate.queryForObject(
                "SELECT count(DISTINCT business_key) FROM " + tableName,
                Long.class
        );
        return Objects.requireNonNull(count, "distinct business key count must not be null");
    }

    private List<SequenceAllocationRecordSnapshot> actualRows(String tableName) {
        return jdbcTemplate.query(
                """
                SELECT business_key, name, numeric_value, occurred_on
                FROM %s
                ORDER BY business_key
                """.formatted(tableName),
                (rs, rowNum) -> new SequenceAllocationRecordSnapshot(
                        rs.getString("business_key"),
                        rs.getString("name"),
                        rs.getBigDecimal("numeric_value"),
                        rs.getDate("occurred_on").toLocalDate()
                )
        );
    }

    private static List<SequenceAllocationRecordSnapshot> expectedRows(List<BenchmarkRecordCommand> commands) {
        return commands.stream()
                .map(command -> new SequenceAllocationRecordSnapshot(
                        command.businessKey(),
                        command.name(),
                        command.numericValue(),
                        command.occurredOn()
                ))
                .toList();
    }

    @TestConfiguration(proxyBeanMethods = false)
    @EntityScan(basePackageClasses = {
            BenchmarkRecord.class,
            JpaSequenceAllocationSizeIntegrationTest.AllocationOneRecord.class,
            JpaSequenceAllocationSizeIntegrationTest.AllocationFiveRecord.class
    })
    static class SequenceAllocationEntityScanConfiguration {
    }

    static class SequenceAllocationSchemaInitializer
            implements ApplicationContextInitializer<ConfigurableApplicationContext> {

        @Override
        public void initialize(ConfigurableApplicationContext applicationContext) {
            applicationContext.getBeanFactory().registerSingleton(
                    "sequenceAllocationSchemaFlywayMigrationStrategy",
                    (FlywayMigrationStrategy) flyway -> {
                        flyway.migrate();
                        createSequenceAllocationSchema(flyway.getConfiguration().getDataSource());
                    }
            );
        }

        private static void createSequenceAllocationSchema(DataSource dataSource) {
            try (Connection connection = dataSource.getConnection();
                    Statement statement = connection.createStatement()) {
                for (String sql : schemaSql()) {
                    statement.execute(sql);
                }
            } catch (SQLException exception) {
                throw new IllegalStateException("Failed to create sequence allocation test schema", exception);
            }
        }

        private static List<String> schemaSql() {
            return List.of(
                    """
                    CREATE SEQUENCE IF NOT EXISTS sequence_allocation_one_record_seq
                    START WITH 1
                    INCREMENT BY 1
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS sequence_allocation_one_record (
                        id BIGINT NOT NULL,
                        business_key VARCHAR(64) NOT NULL,
                        name VARCHAR(100) NOT NULL,
                        numeric_value NUMERIC(19, 4) NOT NULL,
                        occurred_on DATE NOT NULL,
                        created_at TIMESTAMP WITH TIME ZONE NOT NULL,
                        CONSTRAINT pk_sequence_allocation_one_record PRIMARY KEY (id),
                        CONSTRAINT uk_sequence_allocation_one_record_business_key UNIQUE (business_key)
                    )
                    """,
                    "ALTER SEQUENCE sequence_allocation_one_record_seq OWNED BY sequence_allocation_one_record.id",
                    """
                    CREATE SEQUENCE IF NOT EXISTS sequence_allocation_five_record_seq
                    START WITH 1
                    INCREMENT BY 5
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS sequence_allocation_five_record (
                        id BIGINT NOT NULL,
                        business_key VARCHAR(64) NOT NULL,
                        name VARCHAR(100) NOT NULL,
                        numeric_value NUMERIC(19, 4) NOT NULL,
                        occurred_on DATE NOT NULL,
                        created_at TIMESTAMP WITH TIME ZONE NOT NULL,
                        CONSTRAINT pk_sequence_allocation_five_record PRIMARY KEY (id),
                        CONSTRAINT uk_sequence_allocation_five_record_business_key UNIQUE (business_key)
                    )
                    """,
                    "ALTER SEQUENCE sequence_allocation_five_record_seq OWNED BY sequence_allocation_five_record.id"
            );
        }
    }

    @Entity
    @Table(
            name = "sequence_allocation_one_record",
            uniqueConstraints = @UniqueConstraint(
                    name = "uk_sequence_allocation_one_record_business_key",
                    columnNames = "business_key"
            )
    )
    static class AllocationOneRecord {

        @Id
        @GeneratedValue(strategy = GenerationType.SEQUENCE, generator = "sequence_allocation_one_record_seq_generator")
        @SequenceGenerator(
                name = "sequence_allocation_one_record_seq_generator",
                sequenceName = "sequence_allocation_one_record_seq",
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

        protected AllocationOneRecord() {
        }

        private AllocationOneRecord(
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

        static AllocationOneRecord from(BenchmarkRecordCommand command, Instant createdAt) {
            return new AllocationOneRecord(
                    command.businessKey(),
                    command.name(),
                    command.numericValue(),
                    command.occurredOn(),
                    createdAt
            );
        }
    }

    @Entity
    @Table(
            name = "sequence_allocation_five_record",
            uniqueConstraints = @UniqueConstraint(
                    name = "uk_sequence_allocation_five_record_business_key",
                    columnNames = "business_key"
            )
    )
    static class AllocationFiveRecord {

        @Id
        @GeneratedValue(strategy = GenerationType.SEQUENCE, generator = "sequence_allocation_five_record_seq_generator")
        @SequenceGenerator(
                name = "sequence_allocation_five_record_seq_generator",
                sequenceName = "sequence_allocation_five_record_seq",
                allocationSize = 5
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

        protected AllocationFiveRecord() {
        }

        private AllocationFiveRecord(
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

        static AllocationFiveRecord from(BenchmarkRecordCommand command, Instant createdAt) {
            return new AllocationFiveRecord(
                    command.businessKey(),
                    command.name(),
                    command.numericValue(),
                    command.occurredOn(),
                    createdAt
            );
        }
    }

    private record ObservedSave(
            int savedCount,
            long entityInsertCount,
            long prepareStatementCount,
            long nextvalCount,
            List<Long> jdbcBatchExecutions
    ) {
    }

    private record SequenceAllocationRecordSnapshot(
            String businessKey,
            String name,
            BigDecimal numericValue,
            LocalDate occurredOn
    ) {
    }
}
