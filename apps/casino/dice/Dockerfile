# Build stage — runs on the native build host, cross-compiles to the target
# arch so multi-arch (linux/amd64, linux/arm64) images build without QEMU
# emulation (avoids the emulated-arch segfault class, ISI-7049).
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder

# Populated by buildx; default so a plain `docker build` still works.
ARG TARGETOS=linux
ARG TARGETARCH=amd64

WORKDIR /app

# Install protoc and git (needed for go mod download)
RUN apk add --no-cache protobuf protoc git

# Install protoc-gen-go and protoc-gen-go-grpc via go install
ENV PATH=$PATH:/root/go/bin
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12 && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2

# Copy go mod files first
COPY dice/go/go.mod ./
# Copy source files to let go mod figure out dependencies
COPY dice/go/dice-service*.go ./
COPY dice/go/opentelemetry.go ./
COPY dice/go/featureflags.go ./
COPY dice/go/scoring.go ./
COPY dice/go/redis.go ./
RUN go mod tidy

# Copy proto files and generate Go code
COPY proto/dice.proto ./proto/dice.proto
RUN mkdir -p proto && \
    protoc --go_out=. --go_opt=module=vegas-dice-service \
           --go-grpc_out=. --go-grpc_opt=module=vegas-dice-service \
           --proto_path=proto proto/dice.proto && \
    ls -la proto/ && find . -name "*.pb.go" || echo "Proto files generated"

# Source code already copied above for go mod tidy

# Build the application (cross-compiled to the requested target arch)
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -a -installsuffix cgo -o dice-service-grpc dice-service-grpc.go opentelemetry.go featureflags.go scoring.go redis.go

# Runtime stage
FROM alpine:3.21

RUN apk --no-cache add ca-certificates

# Create app directory with proper permissions for non-root user
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser && \
    mkdir -p /app && \
    chown -R appuser:appuser /app

WORKDIR /app

# Copy the binary from builder to /app
COPY --from=builder /app/dice-service-grpc /app/dice-service-grpc

# Set ownership and execute permissions on the binary
RUN chown appuser:appuser /app/dice-service-grpc && \
    chmod +x /app/dice-service-grpc

# Switch to non-root user
USER appuser

# Expose ports
EXPOSE 8083 50053

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8083/health || exit 1

# Run the service
CMD ["/app/dice-service-grpc"]

