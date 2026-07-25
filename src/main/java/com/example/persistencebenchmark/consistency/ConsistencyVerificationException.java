package com.example.persistencebenchmark.consistency;

public class ConsistencyVerificationException extends RuntimeException {

    private final ConsistencyReport report;

    public ConsistencyVerificationException(String message, ConsistencyReport report) {
        super(message);
        this.report = report;
    }

    public ConsistencyReport report() {
        return report;
    }
}
