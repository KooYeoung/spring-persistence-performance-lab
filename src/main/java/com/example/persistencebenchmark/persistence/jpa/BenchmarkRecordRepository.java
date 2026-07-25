package com.example.persistencebenchmark.persistence.jpa;

import com.example.persistencebenchmark.domain.BenchmarkRecord;
import org.springframework.data.jpa.repository.JpaRepository;

public interface BenchmarkRecordRepository extends JpaRepository<BenchmarkRecord, Long> {
}
