package com.example.persistencebenchmark.profiling;

import java.util.Objects;

import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@Profile("exp001")
@RequestMapping("/internal/exp-001")
public class Exp001ProfilingController {

    private final Exp001ProfilingService profilingService;

    public Exp001ProfilingController(Exp001ProfilingService profilingService) {
        this.profilingService = profilingService;
    }

    @PostMapping("/jpa")
    Exp001ProfilingResponse runJpa(@RequestBody Exp001ProfilingRequest request) {
        return profilingService.runJpa(Objects.requireNonNull(request, "request must not be null").count());
    }

    @PostMapping("/jdbc")
    Exp001ProfilingResponse runJdbc(@RequestBody Exp001ProfilingRequest request) {
        return profilingService.runJdbc(Objects.requireNonNull(request, "request must not be null").count());
    }
}
