package com.example.persistencebenchmark.profiling;

public record Exp001ProfilingResponse(
        String path,
        int inputCount,
        int savedCount,
        long elapsedNanos,
        double elapsedMillis,
        boolean valid,
        int rowCount,
        int distinctBusinessKeyCount,
        int missingKeyCount,
        int unexpectedKeyCount,
        int duplicateKeyCount,
        String expectedChecksum,
        String actualChecksum
) {
}
