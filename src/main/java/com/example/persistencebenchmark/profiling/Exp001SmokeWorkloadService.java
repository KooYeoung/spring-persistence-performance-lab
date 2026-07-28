package com.example.persistencebenchmark.profiling;

import java.util.Locale;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.LongSupplier;

import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Service;

@Service
@Profile("exp001")
public class Exp001SmokeWorkloadService {

    static final String SMOKE_PROTOCOL_VERSION = "exp001-smoke-v1";
    static final String CPU_WORKLOAD_VERSION = "cpu-v1";
    static final String ALLOCATION_WORKLOAD_VERSION = "allocation-v1";

    private static final long NANOS_PER_SECOND = 1_000_000_000L;
    private static final long DEFAULT_CPU_TARGET_DURATION_NANOS = Math.multiplyExact(3L, NANOS_PER_SECOND);

    private static final WorkloadSpec DEFAULT_SPEC = new WorkloadSpec(
            DEFAULT_CPU_TARGET_DURATION_NANOS,
            2_500,
            8_192,
            64L * 1024L * 1024L,
            1024 * 1024
    );

    private final WorkloadSpec spec;
    private final LongSupplier nanoClock;
    private final AtomicBoolean active = new AtomicBoolean(false);

    public Exp001SmokeWorkloadService() {
        this(DEFAULT_SPEC, System::nanoTime);
    }

    Exp001SmokeWorkloadService(WorkloadSpec spec) {
        this(spec, System::nanoTime);
    }

    Exp001SmokeWorkloadService(WorkloadSpec spec, LongSupplier nanoClock) {
        this.spec = spec.validate();
        this.nanoClock = nanoClock;
    }

    CpuWorkloadResult runCpu() {
        acquire();
        try {
            long startedAt = nanoClock.getAsLong();
            long checksum = 0x6a09e667f3bcc909L;
            long iterations = 0L;
            long elapsedNanos;

            do {
                for (int index = 0; index < spec.cpuBatchSize(); index++) {
                    checksum = mix(checksum + iterations + index);
                }
                if (Long.MAX_VALUE - iterations < spec.cpuBatchSize()) {
                    throw new IllegalStateException("cpu iterations overflow");
                }
                iterations += spec.cpuBatchSize();
                elapsedNanos = nanoClock.getAsLong() - startedAt;
            } while (elapsedNanos < spec.cpuTargetDurationNanos());

            long durationMillis = TimeUnit.NANOSECONDS.toMillis(Math.max(0L, elapsedNanos));
            boolean success = iterations > 0 && durationMillis >= spec.cpuSuccessLowerBoundMillis();
            return new CpuWorkloadResult(success, iterations, durationMillis, hex(checksum));
        } finally {
            active.set(false);
        }
    }

    AllocationWorkloadResult runAllocation() {
        acquire();
        try {
            int chunks = Math.toIntExact(spec.allocationBytes() / spec.allocationChunkBytes());
            byte[][] retained = new byte[chunks][];
            long allocatedBytes = 0L;
            long checksum = 0xbb67ae8584caa73bL;

            for (int chunkIndex = 0; chunkIndex < chunks; chunkIndex++) {
                byte[] chunk = new byte[spec.allocationChunkBytes()];
                for (int offset = 0; offset < chunk.length; offset += 4_096) {
                    byte value = (byte) ((chunkIndex * 31 + offset) & 0xff);
                    chunk[offset] = value;
                    checksum = mix(checksum ^ value ^ offset);
                }
                chunk[chunk.length - 1] = (byte) chunkIndex;
                checksum = mix(checksum ^ chunk[0] ^ chunk[chunk.length - 1] ^ chunk.length);
                retained[chunkIndex] = chunk;
                allocatedBytes += chunk.length;
            }

            long retainedChecksum = 0L;
            for (byte[] chunk : retained) {
                retainedChecksum += chunk[0];
                retainedChecksum += chunk[chunk.length - 1];
            }
            checksum = mix(checksum ^ retainedChecksum);

            boolean success = allocatedBytes == spec.allocationBytes() && chunks > 0;
            return new AllocationWorkloadResult(
                    success,
                    allocatedBytes,
                    spec.allocationChunkBytes(),
                    chunks,
                    hex(checksum)
            );
        } finally {
            active.set(false);
        }
    }

    private void acquire() {
        if (!active.compareAndSet(false, true)) {
            throw new WorkloadAlreadyActiveException();
        }
    }

    private static long mix(long value) {
        long mixed = value;
        mixed ^= mixed >>> 33;
        mixed *= 0xff51afd7ed558ccdL;
        mixed ^= mixed >>> 33;
        mixed *= 0xc4ceb9fe1a85ec53L;
        mixed ^= mixed >>> 33;
        return mixed;
    }

    private static String hex(long value) {
        return String.format(Locale.ROOT, "%016x", value);
    }

    record WorkloadSpec(
            long cpuTargetDurationNanos,
            long cpuSuccessLowerBoundMillis,
            int cpuBatchSize,
            long allocationBytes,
            int allocationChunkBytes
    ) {
        WorkloadSpec validate() {
            if (cpuTargetDurationNanos <= 0L) {
                throw new IllegalArgumentException("cpuTargetDurationNanos must be positive");
            }
            if (cpuSuccessLowerBoundMillis < 0L) {
                throw new IllegalArgumentException("cpuSuccessLowerBoundMillis must not be negative");
            }
            if (cpuBatchSize <= 0) {
                throw new IllegalArgumentException("cpuBatchSize must be positive");
            }
            if (allocationBytes <= 0L) {
                throw new IllegalArgumentException("allocationBytes must be positive");
            }
            if (allocationChunkBytes <= 0) {
                throw new IllegalArgumentException("allocationChunkBytes must be positive");
            }
            if (allocationBytes % allocationChunkBytes != 0L) {
                throw new IllegalArgumentException("allocationBytes must be a multiple of allocationChunkBytes");
            }
            if ((allocationBytes / allocationChunkBytes) > Integer.MAX_VALUE) {
                throw new IllegalArgumentException("allocation chunk count is too large");
            }
            return this;
        }
    }

    record CpuWorkloadResult(
            boolean success,
            long iterations,
            long durationMillis,
            String checksum
    ) {
    }

    record AllocationWorkloadResult(
            boolean success,
            long allocatedBytes,
            int chunkBytes,
            int chunks,
            String checksum
    ) {
    }

    static class WorkloadAlreadyActiveException extends RuntimeException {
    }
}
