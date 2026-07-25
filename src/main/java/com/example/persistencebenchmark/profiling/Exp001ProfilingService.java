package com.example.persistencebenchmark.profiling;

import java.util.List;

import com.example.persistencebenchmark.consistency.ConsistencyReport;
import com.example.persistencebenchmark.consistency.JdbcConsistencyVerifier;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommandGenerator;
import com.example.persistencebenchmark.persistence.jdbc.JdbcBatchBenchmarkRecordPersistenceService;
import com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Service;

@Service
@Profile("exp001")
public class Exp001ProfilingService {

    private static final int MIN_COUNT = 1;
    private static final int MAX_COUNT = 50_000;

    private final JpaBenchmarkRecordPersistenceService jpaPersistenceService;
    private final JdbcBatchBenchmarkRecordPersistenceService jdbcPersistenceService;
    private final JdbcConsistencyVerifier consistencyVerifier;

    public Exp001ProfilingService(
            JpaBenchmarkRecordPersistenceService jpaPersistenceService,
            JdbcBatchBenchmarkRecordPersistenceService jdbcPersistenceService,
            JdbcConsistencyVerifier consistencyVerifier
    ) {
        this.jpaPersistenceService = jpaPersistenceService;
        this.jdbcPersistenceService = jdbcPersistenceService;
        this.consistencyVerifier = consistencyVerifier;
    }

    public Exp001ProfilingResponse runJpa(int count) {
        validateCount(count);
        List<BenchmarkRecordCommand> commands = BenchmarkRecordCommandGenerator.generate(count);

        long startedAt = System.nanoTime();
        int savedCount = jpaPersistenceService.saveAll(commands);
        long elapsedNanos = System.nanoTime() - startedAt;

        ConsistencyReport report = consistencyVerifier.verify(commands);
        return response("jpa", count, savedCount, elapsedNanos, report);
    }

    public Exp001ProfilingResponse runJdbc(int count) {
        validateCount(count);
        List<BenchmarkRecordCommand> commands = BenchmarkRecordCommandGenerator.generate(count);

        long startedAt = System.nanoTime();
        int savedCount = jdbcPersistenceService.saveAll(commands);
        long elapsedNanos = System.nanoTime() - startedAt;

        ConsistencyReport report = consistencyVerifier.verify(commands);
        return response("jdbc", count, savedCount, elapsedNanos, report);
    }

    private static void validateCount(int count) {
        if (count < MIN_COUNT || count > MAX_COUNT) {
            throw new IllegalArgumentException("count must be between 1 and 50000");
        }
    }

    private static Exp001ProfilingResponse response(
            String path,
            int inputCount,
            int savedCount,
            long elapsedNanos,
            ConsistencyReport report
    ) {
        boolean valid = savedCount == inputCount && !report.hasFailures();
        return new Exp001ProfilingResponse(
                path,
                inputCount,
                savedCount,
                elapsedNanos,
                elapsedNanos / 1_000_000.0,
                valid,
                report.rowCount(),
                report.distinctBusinessKeyCount(),
                report.missingBusinessKeys().size(),
                report.unexpectedBusinessKeys().size(),
                report.duplicateBusinessKeys().size(),
                report.expectedChecksum(),
                report.actualChecksum()
        );
    }
}
