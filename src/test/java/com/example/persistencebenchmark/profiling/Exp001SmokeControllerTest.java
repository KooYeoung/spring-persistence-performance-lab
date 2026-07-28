package com.example.persistencebenchmark.profiling;

import static org.hamcrest.Matchers.matchesPattern;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class Exp001SmokeControllerTest {

    private final Exp001SmokeWorkloadService workloadService = mock(Exp001SmokeWorkloadService.class);
    private final MockMvc mockMvc = MockMvcBuilders
            .standaloneSetup(new Exp001SmokeController(workloadService))
            .build();

    @Test
    void readyReturnsExactSmokeReadinessSchema() throws Exception {
        mockMvc.perform(get("/internal/exp-001/smoke/ready"))
                .andExpect(status().isOk())
                .andExpect(content().json("""
                        {
                          "status": "READY",
                          "phase": "EXP001_SMOKE"
                        }
                        """, true));
    }

    @Test
    void cpuReturnsMinimalWorkloadSchema() throws Exception {
        when(workloadService.runCpu())
                .thenReturn(new Exp001SmokeWorkloadService.CpuWorkloadResult(true, 128, 2_501, "0123456789abcdef"));

        mockMvc.perform(post("/internal/exp-001/smoke/cpu"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.success").value(true))
                .andExpect(jsonPath("$.workload").value("cpu"))
                .andExpect(jsonPath("$.iterations").value(128))
                .andExpect(jsonPath("$.durationMillis").value(2_501))
                .andExpect(jsonPath("$.checksum", matchesPattern("[0-9a-f]{16}")));
    }

    @Test
    void allocationReturnsMinimalWorkloadSchema() throws Exception {
        when(workloadService.runAllocation())
                .thenReturn(new Exp001SmokeWorkloadService.AllocationWorkloadResult(
                        true,
                        67_108_864,
                        1_048_576,
                        64,
                        "fedcba9876543210"
                ));

        mockMvc.perform(post("/internal/exp-001/smoke/allocation"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.success").value(true))
                .andExpect(jsonPath("$.workload").value("allocation"))
                .andExpect(jsonPath("$.allocatedBytes").value(67_108_864))
                .andExpect(jsonPath("$.chunkBytes").value(1_048_576))
                .andExpect(jsonPath("$.chunks").value(64))
                .andExpect(jsonPath("$.checksum", matchesPattern("[0-9a-f]{16}")));
    }

    @Test
    void activeWorkloadReturnsConflict() throws Exception {
        when(workloadService.runCpu())
                .thenThrow(new Exp001SmokeWorkloadService.WorkloadAlreadyActiveException());

        mockMvc.perform(post("/internal/exp-001/smoke/cpu"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.success").value(false))
                .andExpect(jsonPath("$.error").value("smoke workload already active"));
    }
}
