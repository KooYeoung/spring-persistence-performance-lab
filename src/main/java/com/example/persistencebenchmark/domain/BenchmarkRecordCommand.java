package com.example.persistencebenchmark.domain;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Objects;

public record BenchmarkRecordCommand(
        String businessKey,
        String name,
        BigDecimal numericValue,
        LocalDate occurredOn
) {

    public BenchmarkRecordCommand {
        Objects.requireNonNull(businessKey, "businessKey must not be null");
        Objects.requireNonNull(name, "name must not be null");
        Objects.requireNonNull(numericValue, "numericValue must not be null");
        Objects.requireNonNull(occurredOn, "occurredOn must not be null");
    }
}
