package com.example.persistencebenchmark;

import static org.hamcrest.Matchers.matchesPattern;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

@ActiveProfiles("exp001")
@AutoConfigureMockMvc
class Exp001ProfilingEndpointIntegrationTest extends AbstractPostgreSqlIntegrationTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void jpaEndpointPersistsSmallInputAndReturnsConsistencyResult() throws Exception {
        mockMvc.perform(post("/internal/exp-001/jpa")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"count\":3}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.path").value("jpa"))
                .andExpect(jsonPath("$.inputCount").value(3))
                .andExpect(jsonPath("$.savedCount").value(3))
                .andExpect(jsonPath("$.elapsedNanos").isNumber())
                .andExpect(jsonPath("$.valid").value(true))
                .andExpect(jsonPath("$.rowCount").value(3))
                .andExpect(jsonPath("$.distinctBusinessKeyCount").value(3))
                .andExpect(jsonPath("$.missingKeyCount").value(0))
                .andExpect(jsonPath("$.unexpectedKeyCount").value(0))
                .andExpect(jsonPath("$.duplicateKeyCount").value(0))
                .andExpect(jsonPath("$.expectedChecksum", matchesPattern("[0-9a-f]{64}")))
                .andExpect(jsonPath("$.actualChecksum", matchesPattern("[0-9a-f]{64}")));
    }

    @Test
    void jdbcEndpointPersistsSmallInputAndReturnsConsistencyResult() throws Exception {
        mockMvc.perform(post("/internal/exp-001/jdbc")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"count\":4}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.path").value("jdbc"))
                .andExpect(jsonPath("$.inputCount").value(4))
                .andExpect(jsonPath("$.savedCount").value(4))
                .andExpect(jsonPath("$.elapsedNanos").isNumber())
                .andExpect(jsonPath("$.valid").value(true))
                .andExpect(jsonPath("$.rowCount").value(4))
                .andExpect(jsonPath("$.distinctBusinessKeyCount").value(4))
                .andExpect(jsonPath("$.missingKeyCount").value(0))
                .andExpect(jsonPath("$.unexpectedKeyCount").value(0))
                .andExpect(jsonPath("$.duplicateKeyCount").value(0))
                .andExpect(jsonPath("$.expectedChecksum", matchesPattern("[0-9a-f]{64}")))
                .andExpect(jsonPath("$.actualChecksum", matchesPattern("[0-9a-f]{64}")));
    }
}
