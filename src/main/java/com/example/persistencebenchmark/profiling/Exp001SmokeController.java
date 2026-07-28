package com.example.persistencebenchmark.profiling;

import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@Profile("exp001")
@RequestMapping("/internal/exp-001/smoke")
public class Exp001SmokeController {

    private final Exp001SmokeWorkloadService workloadService;

    public Exp001SmokeController(Exp001SmokeWorkloadService workloadService) {
        this.workloadService = workloadService;
    }

    @GetMapping("/ready")
    SmokeReadyResponse ready() {
        return new SmokeReadyResponse(
                "READY",
                "EXP001_SMOKE"
        );
    }

    @PostMapping("/cpu")
    ResponseEntity<?> cpu() {
        try {
            Exp001SmokeWorkloadService.CpuWorkloadResult result = workloadService.runCpu();
            return ResponseEntity.ok(new CpuSmokeResponse(
                    result.success(),
                    "cpu",
                    result.iterations(),
                    result.durationMillis(),
                    result.checksum()
            ));
        } catch (Exp001SmokeWorkloadService.WorkloadAlreadyActiveException exception) {
            return conflict();
        }
    }

    @PostMapping("/allocation")
    ResponseEntity<?> allocation() {
        try {
            Exp001SmokeWorkloadService.AllocationWorkloadResult result = workloadService.runAllocation();
            return ResponseEntity.ok(new AllocationSmokeResponse(
                    result.success(),
                    "allocation",
                    result.allocatedBytes(),
                    result.chunkBytes(),
                    result.chunks(),
                    result.checksum()
            ));
        } catch (Exp001SmokeWorkloadService.WorkloadAlreadyActiveException exception) {
            return conflict();
        }
    }

    private static ResponseEntity<ConflictResponse> conflict() {
        return ResponseEntity
                .status(HttpStatus.CONFLICT)
                .body(new ConflictResponse(false, "smoke workload already active"));
    }

    private record SmokeReadyResponse(
            String status,
            String phase
    ) {
    }

    private record CpuSmokeResponse(
            boolean success,
            String workload,
            long iterations,
            long durationMillis,
            String checksum
    ) {
    }

    private record AllocationSmokeResponse(
            boolean success,
            String workload,
            long allocatedBytes,
            int chunkBytes,
            int chunks,
            String checksum
    ) {
    }

    private record ConflictResponse(boolean success, String error) {
    }
}
