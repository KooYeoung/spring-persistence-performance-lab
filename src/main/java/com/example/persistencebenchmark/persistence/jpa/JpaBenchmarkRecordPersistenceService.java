package com.example.persistencebenchmark.persistence.jpa;

import java.time.Clock;
import java.time.Instant;
import java.util.List;
import java.util.Objects;

import com.example.persistencebenchmark.domain.BenchmarkRecord;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class JpaBenchmarkRecordPersistenceService {

    private final BenchmarkRecordRepository repository;
    private final Clock clock;

    public JpaBenchmarkRecordPersistenceService(BenchmarkRecordRepository repository, Clock clock) {
        this.repository = repository;
        this.clock = clock;
    }

    @Transactional
    public int saveAll(List<BenchmarkRecordCommand> commands) {
        Objects.requireNonNull(commands, "commands must not be null");
        if (commands.isEmpty()) {
            return 0;
        }

        Instant createdAt = clock.instant();
        List<BenchmarkRecord> records = commands.stream()
                .map(command -> BenchmarkRecord.from(command, createdAt))
                .toList();

        List<BenchmarkRecord> savedRecords = repository.saveAll(records);
        repository.flush();
        return savedRecords.size();
    }
}
