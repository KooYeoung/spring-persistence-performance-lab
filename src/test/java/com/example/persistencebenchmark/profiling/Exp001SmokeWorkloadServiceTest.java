package com.example.persistencebenchmark.profiling;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.LongSupplier;

import org.junit.jupiter.api.Test;

class Exp001SmokeWorkloadServiceTest {

    @Test
    void cpuWorkloadRunsForLowerBoundAndProducesDeterministicChecksum() {
        Exp001SmokeWorkloadService.WorkloadSpec spec = smallSpec();
        Exp001SmokeWorkloadService.CpuWorkloadResult first =
                new Exp001SmokeWorkloadService(spec, new StepClock(TimeUnit.MILLISECONDS.toNanos(1))).runCpu();
        Exp001SmokeWorkloadService.CpuWorkloadResult second =
                new Exp001SmokeWorkloadService(spec, new StepClock(TimeUnit.MILLISECONDS.toNanos(1))).runCpu();

        assertThat(first.success()).isTrue();
        assertThat(first.iterations()).isPositive();
        assertThat(first.durationMillis()).isGreaterThanOrEqualTo(spec.cpuSuccessLowerBoundMillis());
        assertThat(first.checksum()).matches("[0-9a-f]{16}");
        assertThat(second).isEqualTo(first);
    }

    @Test
    void cpuWorkloadStopsAtExactTargetBoundary() {
        Exp001SmokeWorkloadService.WorkloadSpec spec = new Exp001SmokeWorkloadService.WorkloadSpec(
                4,
                0,
                4,
                1_024,
                1_024
        );

        Exp001SmokeWorkloadService.CpuWorkloadResult result =
                new Exp001SmokeWorkloadService(spec, new SequenceClock(100, 104)).runCpu();

        assertThat(result.success()).isTrue();
        assertThat(result.iterations()).isEqualTo(4);
        assertThat(result.durationMillis()).isZero();
    }

    @Test
    void cpuWorkloadKeepsRunningUntilTargetIsReached() {
        Exp001SmokeWorkloadService.WorkloadSpec spec = new Exp001SmokeWorkloadService.WorkloadSpec(
                5,
                0,
                4,
                1_024,
                1_024
        );

        Exp001SmokeWorkloadService.CpuWorkloadResult result =
                new Exp001SmokeWorkloadService(spec, new SequenceClock(100, 103, 105)).runCpu();

        assertThat(result.success()).isTrue();
        assertThat(result.iterations()).isEqualTo(8);
    }

    @Test
    void cpuWorkloadHandlesNanoTimeWraparound() {
        Exp001SmokeWorkloadService.WorkloadSpec spec = new Exp001SmokeWorkloadService.WorkloadSpec(
                5,
                0,
                4,
                1_024,
                1_024
        );

        Exp001SmokeWorkloadService.CpuWorkloadResult result = new Exp001SmokeWorkloadService(
                spec,
                new SequenceClock(Long.MAX_VALUE - 2, Long.MIN_VALUE + 2)
        ).runCpu();

        assertThat(result.success()).isTrue();
        assertThat(result.iterations()).isEqualTo(4);
        assertThat(result.durationMillis()).isZero();
    }

    @Test
    void cpuWorkloadRejectsNonPositiveTargetDuration() {
        assertThatThrownBy(() -> new Exp001SmokeWorkloadService.WorkloadSpec(
                0,
                0,
                4,
                1_024,
                1_024
        ).validate())
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("cpuTargetDurationNanos must be positive");

        assertThatThrownBy(() -> new Exp001SmokeWorkloadService.WorkloadSpec(
                -1,
                0,
                4,
                1_024,
                1_024
        ).validate())
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("cpuTargetDurationNanos must be positive");
    }

    @Test
    void allocationWorkloadAllocatesExactBytesAndProducesDeterministicChecksum() {
        Exp001SmokeWorkloadService.WorkloadSpec spec = smallSpec();
        Exp001SmokeWorkloadService.AllocationWorkloadResult first =
                new Exp001SmokeWorkloadService(spec).runAllocation();
        Exp001SmokeWorkloadService.AllocationWorkloadResult second =
                new Exp001SmokeWorkloadService(spec).runAllocation();

        assertThat(first.success()).isTrue();
        assertThat(first.allocatedBytes()).isEqualTo(spec.allocationBytes());
        assertThat(first.chunkBytes()).isEqualTo(spec.allocationChunkBytes());
        assertThat(first.chunks()).isEqualTo(3);
        assertThat(first.checksum()).matches("[0-9a-f]{16}");
        assertThat(second).isEqualTo(first);
    }

    @Test
    void concurrentWorkloadIsRejected() throws Exception {
        BlockingFirstClock clock = new BlockingFirstClock();
        Exp001SmokeWorkloadService service = new Exp001SmokeWorkloadService(
                new Exp001SmokeWorkloadService.WorkloadSpec(
                        TimeUnit.MILLISECONDS.toNanos(1),
                        0,
                        4,
                        1_024,
                        1_024
                ),
                clock
        );
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try {
            Future<Exp001SmokeWorkloadService.CpuWorkloadResult> running = executor.submit(service::runCpu);
            clock.awaitEntered();

            assertThatThrownBy(service::runAllocation)
                    .isInstanceOf(Exp001SmokeWorkloadService.WorkloadAlreadyActiveException.class);

            clock.release();
            assertThat(running.get(1, TimeUnit.SECONDS).success()).isTrue();
        } finally {
            executor.shutdownNow();
        }
    }

    @Test
    void exceptionDuringWorkloadReleasesLock() {
        AtomicReference<LongSupplier> clock = new AtomicReference<>(() -> {
            throw new IllegalStateException("boom");
        });
        Exp001SmokeWorkloadService service = new Exp001SmokeWorkloadService(smallSpec(), () -> clock.get().getAsLong());

        assertThatThrownBy(service::runCpu)
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("boom");

        clock.set(System::nanoTime);
        assertThat(service.runAllocation().success()).isTrue();
    }

    private static Exp001SmokeWorkloadService.WorkloadSpec smallSpec() {
        return new Exp001SmokeWorkloadService.WorkloadSpec(
                TimeUnit.MILLISECONDS.toNanos(5),
                2,
                16,
                12L * 1_024L,
                4 * 1_024
        );
    }

    private static final class StepClock implements LongSupplier {
        private final long stepNanos;
        private long currentNanos;

        private StepClock(long stepNanos) {
            this.stepNanos = stepNanos;
        }

        @Override
        public long getAsLong() {
            currentNanos += stepNanos;
            return currentNanos;
        }
    }

    private static final class SequenceClock implements LongSupplier {
        private final long[] values;
        private int index;

        private SequenceClock(long... values) {
            this.values = values;
        }

        @Override
        public long getAsLong() {
            long value = values[Math.min(index, values.length - 1)];
            index++;
            return value;
        }
    }

    private static final class BlockingFirstClock implements LongSupplier {
        private final CountDownLatch entered = new CountDownLatch(1);
        private final CountDownLatch release = new CountDownLatch(1);
        private final AtomicInteger calls = new AtomicInteger();

        @Override
        public long getAsLong() {
            if (calls.getAndIncrement() == 0) {
                entered.countDown();
                try {
                    release.await(1, TimeUnit.SECONDS);
                } catch (InterruptedException exception) {
                    Thread.currentThread().interrupt();
                    throw new IllegalStateException("interrupted", exception);
                }
                return 0L;
            }
            return TimeUnit.MILLISECONDS.toNanos(10L + calls.get());
        }

        private void awaitEntered() throws InterruptedException {
            assertThat(entered.await(1, TimeUnit.SECONDS)).isTrue();
        }

        private void release() {
            release.countDown();
        }
    }
}
