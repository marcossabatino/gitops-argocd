# Build stage
FROM golang:1.21-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN go mod tidy

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -installsuffix cgo -o load-tester .

# Runtime stage
FROM alpine:3.18

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

COPY --from=builder /app/load-tester .
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 9090

ENTRYPOINT ["./load-tester"]
