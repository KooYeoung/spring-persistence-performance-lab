package com.example.persistencebenchmark.consistency;

import java.util.Collections;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.TreeSet;

public record ConsistencyReport(
        int expectedRowCount,
        int rowCount,
        int distinctBusinessKeyCount,
        Set<String> expectedBusinessKeys,
        Set<String> actualBusinessKeys,
        Set<String> missingBusinessKeys,
        Set<String> unexpectedBusinessKeys,
        Set<String> duplicateBusinessKeys,
        List<NormalizedRecordSnapshot> normalizedRows,
        String expectedChecksum,
        String actualChecksum
) {

    public ConsistencyReport {
        expectedBusinessKeys = sortedCopy(expectedBusinessKeys);
        actualBusinessKeys = sortedCopy(actualBusinessKeys);
        missingBusinessKeys = sortedCopy(missingBusinessKeys);
        unexpectedBusinessKeys = sortedCopy(unexpectedBusinessKeys);
        duplicateBusinessKeys = sortedCopy(duplicateBusinessKeys);
        normalizedRows = List.copyOf(normalizedRows);
    }

    public boolean hasFailures() {
        return rowCount != expectedRowCount
                || distinctBusinessKeyCount != rowCount
                || !missingBusinessKeys.isEmpty()
                || !unexpectedBusinessKeys.isEmpty()
                || !duplicateBusinessKeys.isEmpty()
                || !Objects.equals(expectedChecksum, actualChecksum);
    }

    public String failureSummary() {
        return "expectedRowCount=" + expectedRowCount
                + ", rowCount=" + rowCount
                + ", distinctBusinessKeyCount=" + distinctBusinessKeyCount
                + ", missingBusinessKeys=" + missingBusinessKeys
                + ", unexpectedBusinessKeys=" + unexpectedBusinessKeys
                + ", duplicateBusinessKeys=" + duplicateBusinessKeys
                + ", expectedChecksum=" + expectedChecksum
                + ", actualChecksum=" + actualChecksum;
    }

    public String checksum() {
        return actualChecksum;
    }

    private static Set<String> sortedCopy(Set<String> values) {
        return Collections.unmodifiableSet(new TreeSet<>(values));
    }
}
