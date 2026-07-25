package com.example.persistencebenchmark.consistency;

import java.nio.charset.StandardCharsets;

public record NormalizedRecordSnapshot(
        String businessKey,
        String name,
        String numericValue,
        String occurredOn
) {

    private static final String NULL_FIELD = "-1:";

    String toChecksumLine(String columnDelimiter) {
        return encode(businessKey)
                + columnDelimiter
                + encode(name)
                + columnDelimiter
                + encode(numericValue)
                + columnDelimiter
                + encode(occurredOn);
    }

    private static String encode(String value) {
        if (value == null) {
            return NULL_FIELD;
        }
        return value.getBytes(StandardCharsets.UTF_8).length + ":" + value;
    }
}
