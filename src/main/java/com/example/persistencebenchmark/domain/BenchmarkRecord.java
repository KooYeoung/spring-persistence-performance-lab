package com.example.persistencebenchmark.domain;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.Objects;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import jakarta.persistence.UniqueConstraint;

@Entity
@Table(
        name = "benchmark_record",
        uniqueConstraints = @UniqueConstraint(
                name = "uk_benchmark_record_business_key",
                columnNames = "business_key"
        )
)
public class BenchmarkRecord {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
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

    protected BenchmarkRecord() {
    }

    public BenchmarkRecord(
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

    public static BenchmarkRecord from(BenchmarkRecordCommand command, Instant createdAt) {
        return new BenchmarkRecord(
                command.businessKey(),
                command.name(),
                command.numericValue(),
                command.occurredOn(),
                createdAt
        );
    }

    public Long getId() {
        return id;
    }

    public String getBusinessKey() {
        return businessKey;
    }

    public String getName() {
        return name;
    }

    public BigDecimal getNumericValue() {
        return numericValue;
    }

    public LocalDate getOccurredOn() {
        return occurredOn;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }
}
