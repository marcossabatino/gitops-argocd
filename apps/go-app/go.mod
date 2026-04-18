module github.com/obs/go-app

go 1.21

require (
    github.com/prometheus/client_golang v1.18.0
    go.opentelemetry.io/otel v1.21.0
    go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.21.0
    go.opentelemetry.io/otel/sdk v1.21.0
    go.opentelemetry.io/otel/trace v1.21.0
    go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.46.1
)
