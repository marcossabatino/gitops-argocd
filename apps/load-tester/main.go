package main

import (
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	requestsSent = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "load_tester_requests_sent_total",
			Help: "Total requests sent by load tester",
		},
		[]string{"target", "endpoint", "status"},
	)

	requestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "load_tester_request_duration_seconds",
			Help:    "Request duration observed by load tester",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
		},
		[]string{"target", "endpoint"},
	)

	activeRequests = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "load_tester_active_requests",
			Help: "Number of active requests",
		},
		[]string{"target"},
	)
)

func init() {
	prometheus.MustRegister(requestsSent, requestDuration, activeRequests)
}

type LoadTester struct {
	targets      []string
	baseRPS      int
	replicaIndex int
	healthRatio  float64
	slowRatio    float64
	errorRatio   float64
}

func NewLoadTester() *LoadTester {
	targets := strings.Split(os.Getenv("TARGETS"), ",")
	baseRPS := 10
	if rps := os.Getenv("BASE_RPS"); rps != "" {
		if n, err := strconv.Atoi(rps); err == nil {
			baseRPS = n
		}
	}

	lt := &LoadTester{
		targets:     targets,
		baseRPS:     baseRPS,
		healthRatio: 0.7,
		slowRatio:   0.2,
		errorRatio:  0.1,
	}

	if hr := os.Getenv("HEALTH_RATIO"); hr != "" {
		if f, err := strconv.ParseFloat(hr, 64); err == nil {
			lt.healthRatio = f
		}
	}
	if sr := os.Getenv("SLOW_RATIO"); sr != "" {
		if f, err := strconv.ParseFloat(sr, 64); err == nil {
			lt.slowRatio = f
		}
	}
	if er := os.Getenv("ERROR_RATIO"); er != "" {
		if f, err := strconv.ParseFloat(er, 64); err == nil {
			lt.errorRatio = f
		}
	}

	return lt
}

func (lt *LoadTester) chooseEndpoint() string {
	r := rand.Float64()
	if r < lt.healthRatio {
		return "/health"
	} else if r < lt.healthRatio+lt.slowRatio {
		return "/simulate-slow"
	}
	return "/simulate-error"
}

func (lt *LoadTester) sendRequest(target string) {
	client := &http.Client{
		Timeout: 10 * time.Second,
	}

	endpoint := lt.chooseEndpoint()
	url := fmt.Sprintf("%s%s", target, endpoint)

	start := time.Now()
	activeRequests.WithLabelValues(target).Inc()
	defer activeRequests.WithLabelValues(target).Dec()

	resp, err := client.Get(url)
	duration := time.Since(start).Seconds()

	status := "error"
	if err == nil {
		status = fmt.Sprintf("%d", resp.StatusCode)
		resp.Body.Close()
	}

	requestDuration.WithLabelValues(target, endpoint).Observe(duration)
	requestsSent.WithLabelValues(target, endpoint, status).Inc()

	if err != nil {
		log.Printf("Request to %s failed: %v", url, err)
	}
}

func (lt *LoadTester) start(ctx chan struct{}, wg *sync.WaitGroup) {
	defer wg.Done()

	// Calculate RPS per target
	rpsPerTarget := lt.baseRPS / len(lt.targets)
	if rpsPerTarget == 0 {
		rpsPerTarget = 1
	}

	ticker := time.NewTicker(time.Duration(1000/rpsPerTarget) * time.Millisecond)
	defer ticker.Stop()

	log.Printf("Load tester started: %d RPS to %d targets (%.1f RPS per target)", lt.baseRPS, len(lt.targets), float64(rpsPerTarget))

	targetIndex := 0
	for {
		select {
		case <-ctx:
			log.Println("Load tester stopping...")
			return
		case <-ticker.C:
			target := lt.targets[targetIndex%len(lt.targets)]
			go lt.sendRequest(target)
			targetIndex++
		}
	}
}

func main() {
	lt := NewLoadTester()

	log.Printf("Targets: %v", lt.targets)
	log.Printf("Health ratio: %.2f, Slow ratio: %.2f, Error ratio: %.2f", lt.healthRatio, lt.slowRatio, lt.errorRatio)

	// Start metrics server
	go func() {
		http.Handle("/metrics", promhttp.Handler())
		log.Println("Metrics server listening on :9090")
		if err := http.ListenAndServe(":9090", nil); err != nil {
			log.Fatalf("Metrics server error: %v", err)
		}
	}()

	// Start load generator
	ctx := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)

	go lt.start(ctx, &wg)

	// Wait for interrupt
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt)
	<-sigChan

	close(ctx)
	wg.Wait()
	log.Println("Load tester stopped")
}
