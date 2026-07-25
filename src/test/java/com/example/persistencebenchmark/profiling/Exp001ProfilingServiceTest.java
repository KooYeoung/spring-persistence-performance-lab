package com.example.persistencebenchmark.profiling;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.util.List;
import java.util.Set;
import java.util.TreeSet;

import com.example.persistencebenchmark.consistency.ConsistencyReport;
import com.example.persistencebenchmark.consistency.JdbcConsistencyVerifier;
import com.example.persistencebenchmark.domain.BenchmarkRecordCommand;
import com.example.persistencebenchmark.persistence.jdbc.JdbcBatchBenchmarkRecordPersistenceService;
import com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;

class Exp001ProfilingServiceTest {

    private final JpaBenchmarkRecordPersistenceService jpaPersistenceService =
            mock(JpaBenchmarkRecordPersistenceService.class);
    private final JdbcBatchBenchmarkRecordPersistenceService jdbcPersistenceService =
            mock(JdbcBatchBenchmarkRecordPersistenceService.class);
    private final JdbcConsistencyVerifier consistencyVerifier = mock(JdbcConsistencyVerifier.class);
    private final Exp001ProfilingService profilingService = new Exp001ProfilingService(
            jpaPersistenceService,
            jdbcPersistenceService,
            consistencyVerifier
    );

    @Test
    void jpaRunGeneratesDeterministicCommandsBeforePersistenceAndVerifiesAfterPersistence() {
        when(jpaPersistenceService.saveAll(anyList())).thenReturn(2);
        when(consistencyVerifier.verify(anyList()))
                .thenAnswer(invocation -> reportFor(invocation.getArgument(0)));

        Exp001ProfilingResponse response = profilingService.runJpa(2);

        ArgumentCaptor<List<BenchmarkRecordCommand>> commandsCaptor = commandListCaptor();
        InOrder inOrder = inOrder(jpaPersistenceService, consistencyVerifier);
        inOrder.verify(jpaPersistenceService).saveAll(commandsCaptor.capture());
        inOrder.verify(consistencyVerifier).verify(commandsCaptor.getValue());
        verifyNoInteractions(jdbcPersistenceService);

        List<BenchmarkRecordCommand> commands = commandsCaptor.getValue();
        assertThat(commands).extracting(BenchmarkRecordCommand::businessKey)
                .containsExactly("record-000001", "record-000002");
        assertThat(response.path()).isEqualTo("jpa");
        assertThat(response.inputCount()).isEqualTo(2);
        assertThat(response.savedCount()).isEqualTo(2);
        assertThat(response.elapsedNanos()).isPositive();
        assertThat(response.valid()).isTrue();
        assertThat(response.rowCount()).isEqualTo(2);
        assertThat(response.distinctBusinessKeyCount()).isEqualTo(2);
        assertThat(response.missingKeyCount()).isZero();
        assertThat(response.unexpectedKeyCount()).isZero();
        assertThat(response.duplicateKeyCount()).isZero();
        assertThat(response.expectedChecksum()).isEqualTo(response.actualChecksum());
    }

    @Test
    void jdbcRunCallsJdbcPersistenceAndVerifiesAfterPersistence() {
        when(jdbcPersistenceService.saveAll(anyList())).thenReturn(3);
        when(consistencyVerifier.verify(anyList()))
                .thenAnswer(invocation -> reportFor(invocation.getArgument(0)));

        Exp001ProfilingResponse response = profilingService.runJdbc(3);

        ArgumentCaptor<List<BenchmarkRecordCommand>> commandsCaptor = commandListCaptor();
        InOrder inOrder = inOrder(jdbcPersistenceService, consistencyVerifier);
        inOrder.verify(jdbcPersistenceService).saveAll(commandsCaptor.capture());
        inOrder.verify(consistencyVerifier).verify(commandsCaptor.getValue());
        verifyNoInteractions(jpaPersistenceService);

        assertThat(response.path()).isEqualTo("jdbc");
        assertThat(response.inputCount()).isEqualTo(3);
        assertThat(response.savedCount()).isEqualTo(3);
        assertThat(response.valid()).isTrue();
    }

    @Test
    void countBelowOneFailsBeforePersistence() {
        assertThatThrownBy(() -> profilingService.runJpa(0))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("count must be between 1 and 50000");

        verifyNoInteractions(jpaPersistenceService, jdbcPersistenceService, consistencyVerifier);
    }

    @Test
    void countAboveLimitFailsBeforePersistence() {
        assertThatThrownBy(() -> profilingService.runJdbc(50_001))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("count must be between 1 and 50000");

        verifyNoInteractions(jpaPersistenceService, jdbcPersistenceService, consistencyVerifier);
    }

    @Test
    void savedCountMismatchMakesResponseInvalid() {
        when(jpaPersistenceService.saveAll(anyList())).thenReturn(1);
        when(consistencyVerifier.verify(anyList()))
                .thenAnswer(invocation -> reportFor(invocation.getArgument(0)));

        Exp001ProfilingResponse response = profilingService.runJpa(2);

        assertThat(response.valid()).isFalse();
        assertThat(response.savedCount()).isEqualTo(1);
        assertThat(response.rowCount()).isEqualTo(2);
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private static ArgumentCaptor<List<BenchmarkRecordCommand>> commandListCaptor() {
        return ArgumentCaptor.forClass((Class) List.class);
    }

    private static ConsistencyReport reportFor(List<BenchmarkRecordCommand> commands) {
        Set<String> businessKeys = commands.stream()
                .map(BenchmarkRecordCommand::businessKey)
                .collect(TreeSet::new, TreeSet::add, TreeSet::addAll);
        return new ConsistencyReport(
                commands.size(),
                commands.size(),
                commands.size(),
                businessKeys,
                businessKeys,
                Set.of(),
                Set.of(),
                Set.of(),
                List.of(),
                "checksum",
                "checksum"
        );
    }
}
