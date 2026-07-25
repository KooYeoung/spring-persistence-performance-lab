package com.example.persistencebenchmark.consistency;

import java.util.List;

import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;

public interface ConsistencyVerifier {

    ConsistencyReport verify(List<BenchmarkRecordCommand> expectedCommands);
}
