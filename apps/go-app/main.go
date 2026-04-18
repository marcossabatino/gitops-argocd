package main

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/resource"
	"go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.21.0"
)

var (
	httpDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request duration in seconds",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
		},
		[]string{"method", "path", "status"},
	)

	httpRequests = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests",
		},
		[]string{"method", "path", "status"},
	)
)

func init() {
	prometheus.MustRegister(httpDuration, httpRequests)
}

func initTracer() (*trace.TracerProvider, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		endpoint = "otel-collector.monitoring.svc.cluster.local:4317"
	}

	exporter, err := otlptracegrpc.New(context.Background(),
		otlptracegrpc.WithEndpoint(endpoint),
		otlptracegrpc.WithInsecure(),
	)
	if err != nil {
		return nil, err
	}

	res, err := resource.New(context.Background(),
		resource.WithAttributes(
			semconv.ServiceNameKey.String("go-app"),
		),
	)
	if err != nil {
		return nil, err
	}

	tp := trace.NewTracerProvider(
		trace.WithBatcher(exporter),
		trace.WithResource(res),
	)

	otel.SetTracerProvider(tp)
	return tp, nil
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	defer func() {
		duration := time.Since(start).Seconds()
		httpDuration.WithLabelValues("GET", "/health", "200").Observe(duration)
		httpRequests.WithLabelValues("GET", "/health", "200").Inc()
	}()

	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "OK")
}

func simulateSlowHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	sleepDuration := time.Duration(1000+rand.Intn(2000)) * time.Millisecond
	time.Sleep(sleepDuration)

	duration := time.Since(start).Seconds()
	httpDuration.WithLabelValues("GET", "/simulate-slow", "200").Observe(duration)
	httpRequests.WithLabelValues("GET", "/simulate-slow", "200").Inc()

	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "Slow endpoint completed")
}

func simulateErrorHandler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	status := http.StatusOK
	if rand.Float32() < 0.5 {
		status = http.StatusInternalServerError
	}

	duration := time.Since(start).Seconds()
	httpDuration.WithLabelValues("GET", "/simulate-error", fmt.Sprintf("%d", status)).Observe(duration)
	httpRequests.WithLabelValues("GET", "/simulate-error", fmt.Sprintf("%d", status)).Inc()

	w.WriteHeader(status)
	if status == http.StatusInternalServerError {
		fmt.Fprint(w, "Internal Server Error")
	} else {
		fmt.Fprint(w, "OK")
	}
}

func main() {
	tp, err := initTracer()
	if err != nil {
		log.Fatalf("Failed to initialize tracer: %v", err)
	}
	defer func() {
		if err = tp.Shutdown(context.Background()); err != nil {
			log.Printf("Failed to shutdown tracer: %v", err)
		}
	}()

	mux := http.NewServeMux()

	// Endpoints with OTel instrumentation
	mux.HandleFunc("/health", otelhttp.NewHandler(http.HandlerFunc(healthHandler), "/health").ServeHTTP)
	mux.HandleFunc("/simulate-slow", otelhttp.NewHandler(http.HandlerFunc(simulateSlowHandler), "/simulate-slow").ServeHTTP)
	mux.HandleFunc("/simulate-error", otelhttp.NewHandler(http.HandlerFunc(simulateErrorHandler), "/simulate-error").ServeHTTP)

	// Prometheus metrics endpoint
	mux.Handle("/metrics", promhttp.Handler())

	server := &http.Server{
		Addr:    ":8080",
		Handler: mux,
	}

	go func() {
		log.Printf("Server listening on %s", server.Addr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	}()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	<-sigChan

	log.Println("Shutting down server...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Fatalf("Shutdown error: %v", err)
	}
}
