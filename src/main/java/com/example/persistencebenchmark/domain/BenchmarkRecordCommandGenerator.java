package com.example.persistencebenchmark.domain;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Locale;
import java.util.stream.IntStream;

public final class BenchmarkRecordCommandGenerator {

    private static final LocalDate BASE_DATE = LocalDate.of(2024, 1, 1);

    private BenchmarkRecordCommandGenerator() {
    }

    public static List<BenchmarkRecordCommand> generate(int count) {
        if (count < 0) {
            throw new IllegalArgumentException("count must not be negative");
        }

        return IntStream.rangeClosed(1, count)
                .mapToObj(BenchmarkRecordCommandGenerator::generateOne)
                .toList();
    }

    public static BenchmarkRecordCommand generateOne(int sequence) {
        if (sequence <= 0) {
            throw new IllegalArgumentException("sequence must be positive");
        }

        return new BenchmarkRecordCommand(
                String.format(Locale.ROOT, "record-%06d", sequence),
                String.format(Locale.ROOT, "Synthetic Record %06d", sequence),
                BigDecimal.valueOf(sequence).setScale(4),
                BASE_DATE.plusDays(sequence - 1L)
        );
    }
}
