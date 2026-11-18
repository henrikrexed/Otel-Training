# Multi-stage build for Java Spring Boot application
FROM maven:3.9-eclipse-temurin-17 AS builder

WORKDIR /app

# Copy pom.xml and download dependencies
COPY scoring/pom.xml .
RUN mvn dependency:go-offline -B

# Copy source code and build
COPY scoring/src ./src
RUN mvn clean package -DskipTests -B

# Runtime stage.
# Use the Ubuntu-based Temurin JRE (multi-arch: linux/amd64 + linux/arm64).
# The -alpine (musl) Temurin JRE is published for amd64 only, so it breaks the
# arm64 leg of the multi-arch build.
FROM eclipse-temurin:17-jre

WORKDIR /app

# wget for the container HEALTHCHECK (not shipped in the base image).
RUN apt-get update && \
    apt-get install -y --no-install-recommends wget && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user (Debian-style tools, not Alpine busybox)
RUN groupadd -g 1000 appuser && \
    useradd -u 1000 -g appuser -m -s /usr/sbin/nologin appuser && \
    mkdir -p /app && \
    chown -R appuser:appuser /app

# Copy JAR from builder
COPY --from=builder /app/target/scoring-service-*.jar /app/scoring-service.jar

# Set permissions
RUN chown appuser:appuser /app/scoring-service.jar && \
    chmod +x /app/scoring-service.jar

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 8085

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8085/api/scoring/health || exit 1

# Start the application
ENTRYPOINT ["java", "-jar", "/app/scoring-service.jar"]








