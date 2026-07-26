package com.example.persistencebenchmark.profiling;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.autoconfigure.http.HttpMessageConvertersAutoConfiguration;
import org.springframework.boot.autoconfigure.jackson.JacksonAutoConfiguration;
import org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration;
import org.springframework.boot.test.context.runner.WebApplicationContextRunner;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Import;
import org.springframework.web.servlet.mvc.method.annotation.RequestMappingHandlerMapping;

class Exp001ProfilingProfileTest {

    private final WebApplicationContextRunner contextRunner = new WebApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(
                    JacksonAutoConfiguration.class,
                    HttpMessageConvertersAutoConfiguration.class,
                    WebMvcAutoConfiguration.class
            ))
            .withUserConfiguration(ControllerConfiguration.class)
            .withBean(Exp001ProfilingService.class, () -> mock(Exp001ProfilingService.class));

    @Test
    void defaultProfileDoesNotRegisterProfilingEndpoint() {
        contextRunner.run(context ->
                assertThat(context).doesNotHaveBean(Exp001ProfilingController.class)
        );
    }

    @Test
    void exp001ProfileRegistersProfilingEndpoints() {
        contextRunner
                .withPropertyValues("spring.profiles.active=exp001")
                .run(context -> {
                    assertThat(context).hasSingleBean(Exp001ProfilingController.class);
                    RequestMappingHandlerMapping mapping = context.getBean(RequestMappingHandlerMapping.class);
                    assertThat(mapping.getHandlerMethods().keySet())
                            .anySatisfy(info -> assertThat(info.toString()).contains("/internal/exp-001/jpa"))
                            .anySatisfy(info -> assertThat(info.toString()).contains("/internal/exp-001/jdbc"));
                });
    }

    @Configuration
    @Import(Exp001ProfilingController.class)
    static class ControllerConfiguration {
    }
}
