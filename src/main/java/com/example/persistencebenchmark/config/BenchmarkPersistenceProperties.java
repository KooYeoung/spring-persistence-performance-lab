package com.example.persistencebenchmark.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "lab.persistence")
public record BenchmarkPersistenceProperties(int jdbcBatchSize) {

    public BenchmarkPersistenceProperties {
        if (jdbcBatchSize <= 0) {
            throw new IllegalArgumentException("jdbcBatchSize must be positive");
        }
    }
}
