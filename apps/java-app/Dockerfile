# Build stage
FROM maven:3.9-eclipse-temurin-21-alpine AS builder

WORKDIR /app

COPY pom.xml .
RUN mvn dependency:go-offline

COPY src/ src/
RUN mvn clean package -DskipTests

# OTel Java Agent stage
FROM eclipse-temurin:21-jre-alpine AS otel-agent-stage

ARG OTEL_VERSION=1.32.0

RUN mkdir -p /opt && \
    cd /opt && \
    wget -q https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_VERSION}/opentelemetry-javaagent.jar

# Runtime stage
FROM eclipse-temurin:21-jre-alpine

WORKDIR /app

COPY --from=builder /app/target/*.jar app.jar
COPY --from=otel-agent-stage /opt/opentelemetry-javaagent.jar /opt/otel-javaagent.jar

# Non-root user
RUN addgroup -g 1000 appgroup && \
    adduser -D -u 1000 -G appgroup appuser

USER appuser

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "app.jar"]
