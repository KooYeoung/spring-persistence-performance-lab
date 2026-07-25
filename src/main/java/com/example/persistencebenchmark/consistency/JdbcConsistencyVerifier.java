package com.example.persistencebenchmark.consistency;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.TreeSet;
import java.util.stream.Collectors;

import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class JdbcConsistencyVerifier implements ConsistencyVerifier {

    private static final String COLUMN_DELIMITER = "\u001F";
    private static final String ROW_DELIMITER = "\n";

    private final JdbcTemplate jdbcTemplate;

    public JdbcConsistencyVerifier(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    @Override
    @Transactional(readOnly = true)
    public ConsistencyReport verify(List<BenchmarkRecordCommand> expectedCommands) {
        Objects.requireNonNull(expectedCommands, "expectedCommands must not be null");

        List<NormalizedRecordSnapshot> expectedSnapshots = expectedSnapshots(expectedCommands);
        List<NormalizedRecordSnapshot> actualSnapshots = readNormalizedSnapshots();
        Set<String> expectedBusinessKeys = expectedBusinessKeys(expectedCommands);
        Set<String> actualBusinessKeys = actualBusinessKeys(actualSnapshots);
        Set<String> duplicateBusinessKeys = duplicateBusinessKeys();
        Set<String> missingBusinessKeys = difference(expectedBusinessKeys, actualBusinessKeys);
        Set<String> unexpectedBusinessKeys = difference(actualBusinessKeys, expectedBusinessKeys);

        ConsistencyReport report = new ConsistencyReport(
                expectedCommands.size(),
                queryCount("SELECT COUNT(*) FROM benchmark_record"),
                queryCount("SELECT COUNT(DISTINCT business_key) FROM benchmark_record"),
                expectedBusinessKeys,
                actualBusinessKeys,
                missingBusinessKeys,
                unexpectedBusinessKeys,
                duplicateBusinessKeys,
                actualSnapshots,
                checksum(expectedSnapshots),
                checksum(actualSnapshots)
        );

        if (report.hasFailures()) {
            throw new ConsistencyVerificationException(report.failureSummary(), report);
        }

        return report;
    }

    private List<NormalizedRecordSnapshot> readNormalizedSnapshots() {
        return jdbcTemplate.query(
                """
                        SELECT business_key, name, numeric_value, occurred_on
                        FROM benchmark_record
                        ORDER BY business_key ASC
                        """,
                (resultSet, rowNumber) -> new NormalizedRecordSnapshot(
                        resultSet.getString("business_key"),
                        resultSet.getString("name"),
                        formatNumericValue(resultSet.getBigDecimal("numeric_value")),
                        formatOccurredOn(resultSet.getObject("occurred_on", LocalDate.class))
                )
        );
    }

    private int queryCount(String sql) {
        Long count = jdbcTemplate.queryForObject(sql, Long.class);
        return Math.toIntExact(Objects.requireNonNull(count, "count query returned null"));
    }

    private Set<String> duplicateBusinessKeys() {
        return new TreeSet<>(jdbcTemplate.queryForList(
                """
                        SELECT business_key
                        FROM benchmark_record
                        GROUP BY business_key
                        HAVING COUNT(*) > 1
                        ORDER BY business_key ASC
                        """,
                String.class
        ));
    }

    private static List<NormalizedRecordSnapshot> expectedSnapshots(List<BenchmarkRecordCommand> expectedCommands) {
        return expectedCommands.stream()
                .map(command -> new NormalizedRecordSnapshot(
                        command.businessKey(),
                        command.name(),
                        formatNumericValue(command.numericValue()),
                        formatOccurredOn(command.occurredOn())
                ))
                .sorted(Comparator.comparing(NormalizedRecordSnapshot::businessKey))
                .toList();
    }

    private static Set<String> expectedBusinessKeys(List<BenchmarkRecordCommand> expectedCommands) {
        return expectedCommands.stream()
                .map(BenchmarkRecordCommand::businessKey)
                .collect(Collectors.toCollection(TreeSet::new));
    }

    private static Set<String> actualBusinessKeys(List<NormalizedRecordSnapshot> snapshots) {
        return snapshots.stream()
                .map(NormalizedRecordSnapshot::businessKey)
                .collect(Collectors.toCollection(TreeSet::new));
    }

    private static Set<String> difference(Set<String> left, Set<String> right) {
        Set<String> result = new TreeSet<>(left);
        result.removeAll(right);
        return result;
    }

    private static String checksum(List<NormalizedRecordSnapshot> snapshots) {
        String payload = snapshots.stream()
                .map(snapshot -> snapshot.toChecksumLine(COLUMN_DELIMITER))
                .collect(Collectors.joining(ROW_DELIMITER));

        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(payload.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is not available", exception);
        }
    }

    private static String formatNumericValue(BigDecimal value) {
        if (value == null) {
            return null;
        }
        return value.setScale(4, RoundingMode.UNNECESSARY).toPlainString();
    }

    private static String formatOccurredOn(LocalDate value) {
        if (value == null) {
            return null;
        }
        return DateTimeFormatter.ISO_LOCAL_DATE.format(value);
    }
}
