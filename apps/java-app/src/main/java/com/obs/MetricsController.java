package com.obs;

import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Random;

@RestController
public class MetricsController {
    private static final Logger log = LoggerFactory.getLogger(MetricsController.class);
    private final Random random = new Random();

    @Autowired
    private MeterRegistry meterRegistry;

    @GetMapping("/health")
    public ResponseEntity<String> health() {
        return ResponseEntity.ok("OK");
    }

    @GetMapping("/simulate-slow")
    public ResponseEntity<String> simulateSlow() throws InterruptedException {
        Timer.Sample sample = Timer.start(meterRegistry);

        try {
            long sleepMs = 1000 + random.nextLong(2000);
            Thread.sleep(sleepMs);
            return ResponseEntity.ok("Slow endpoint completed");
        } finally {
            sample.stop(Timer.builder("http_request_duration_seconds")
                    .description("HTTP request duration")
                    .publishPercentiles(0.5, 0.95, 0.99)
                    .register(meterRegistry));
        }
    }

    @GetMapping("/simulate-error")
    public ResponseEntity<String> simulateError() {
        if (random.nextDouble() < 0.5) {
            meterRegistry.counter("http_requests_total", "status", "500").increment();
            return ResponseEntity.status(500).body("Internal Server Error");
        }
        meterRegistry.counter("http_requests_total", "status", "200").increment();
        return ResponseEntity.ok("OK");
    }
}
