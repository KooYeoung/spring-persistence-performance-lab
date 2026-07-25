package com.example.persistencebenchmark.consistency;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

import org.junit.jupiter.api.Test;

class NormalizedRecordSnapshotTest {

    private static final String COLUMN_DELIMITER = "\u001F";

    @Test
    void lengthPrefixedPayloadAvoidsColumnDelimiterCollision() {
        NormalizedRecordSnapshot first = new NormalizedRecordSnapshot(
                "a",
                "b\u001Fc",
                "1.0000",
                "2024-01-01"
        );
        NormalizedRecordSnapshot second = new NormalizedRecordSnapshot(
                "a\u001Fb",
                "c",
                "1.0000",
                "2024-01-01"
        );

        String firstPayload = first.toChecksumLine(COLUMN_DELIMITER);
        String secondPayload = second.toChecksumLine(COLUMN_DELIMITER);

        assertThat(firstPayload).isNotEqualTo(secondPayload);
        assertThat(sha256Hex(firstPayload)).isNotEqualTo(sha256Hex(secondPayload));
    }

    @Test
    void lengthPrefixedPayloadAvoidsRowDelimiterCollision() {
        NormalizedRecordSnapshot first = new NormalizedRecordSnapshot(
                "a",
                "b\nc",
                "1.0000",
                "2024-01-01"
        );
        NormalizedRecordSnapshot second = new NormalizedRecordSnapshot(
                "a\nb",
                "c",
                "1.0000",
                "2024-01-01"
        );

        String firstPayload = first.toChecksumLine(COLUMN_DELIMITER);
        String secondPayload = second.toChecksumLine(COLUMN_DELIMITER);

        assertThat(firstPayload).isNotEqualTo(secondPayload);
        assertThat(sha256Hex(firstPayload)).isNotEqualTo(sha256Hex(secondPayload));
    }

    @Test
    void nullEncodingIsDistinctFromTextValue() {
        NormalizedRecordSnapshot nullValue = new NormalizedRecordSnapshot(
                "a",
                null,
                "1.0000",
                "2024-01-01"
        );
        NormalizedRecordSnapshot textValue = new NormalizedRecordSnapshot(
                "a",
                "null",
                "1.0000",
                "2024-01-01"
        );

        assertThat(nullValue.toChecksumLine(COLUMN_DELIMITER))
                .isNotEqualTo(textValue.toChecksumLine(COLUMN_DELIMITER));
    }

    private static String sha256Hex(String payload) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(payload.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is not available", exception);
        }
    }
}
