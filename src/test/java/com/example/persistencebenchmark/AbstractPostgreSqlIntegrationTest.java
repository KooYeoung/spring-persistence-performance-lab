package com.example.persistencebenchmark;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.stream.Collectors;

import com.example.persistencebenchmark.consistency.ConsistencyReport;
import com.example.persistencebenchmark.consistency.ConsistencyVerifier;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommandGenerator;
import org.junit.jupiter.api.BeforeEach;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

@SpringBootTest
abstract class AbstractPostgreSqlIntegrationTest {

    private static final DockerImageName POSTGRES_IMAGE = DockerImageName.parse("postgres:17.6-alpine");

    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>(POSTGRES_IMAGE)
            .withDatabaseName("persistence_lab_test")
            .withUsername("test_user")
            .withPassword("test_password");

    static {
        POSTGRES.start();
    }

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @Autowired
    private ConsistencyVerifier consistencyVerifier;

    @DynamicPropertySource
    static void registerDatabaseProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
        registry.add("lab.persistence.jdbc-batch-size", () -> "3");
    }

    @BeforeEach
    void resetDisposableTestDatabase() {
        jdbcTemplate.execute("TRUNCATE TABLE benchmark_record RESTART IDENTITY");
    }

    protected ConsistencyReport verifyExpected(List<BenchmarkRecordCommand> commands) {
        return consistencyVerifier.verify(commands);
    }

    protected void resetRecords() {
        resetDisposableTestDatabase();
    }

    protected JdbcTemplate jdbcTemplate() {
        return jdbcTemplate;
    }

    protected static Set<String> businessKeysOf(List<BenchmarkRecordCommand> commands) {
        return commands.stream()
                .map(BenchmarkRecordCommand::businessKey)
                .collect(Collectors.toCollection(TreeSet::new));
    }

    protected static List<BenchmarkRecordCommand> generatedCommands(int count) {
        return BenchmarkRecordCommandGenerator.generate(count);
    }

    protected static List<BenchmarkRecordCommand> duplicateBusinessKeyCommands() {
        BenchmarkRecordCommand first = BenchmarkRecordCommandGenerator.generateOne(1);
        BenchmarkRecordCommand duplicate = new BenchmarkRecordCommand(
                first.businessKey(),
                "Synthetic Duplicate",
                BigDecimal.valueOf(999).setScale(4),
                LocalDate.of(2024, 2, 1)
        );
        return List.of(first, duplicate);
    }
}
