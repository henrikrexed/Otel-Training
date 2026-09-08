# Planted Defects Analysis - Perform-Hackathon-2026

This document validates the planted defects against the actual Vegas Casino codebase and provides specific file locations, broken snippets, fixes, and expected Dynatrace evidence for each defect.

## Defect Inventory

### 1. Game Service Propagation Issues - Traces Stop at Frontend
**Module**: M1 - Core Principles  
**Status**: ✅ CONFIRMED - Multiple Critical Import Path Defects

#### Files Affected:
- `/mnt/nas/projects/Perform-Hackathon-2026/services/frontend/frontend-service.js` - Line 12
- `/mnt/nas/projects/Perform-Hackathon-2026/services/slots/index.js` - Line 7  
- `/mnt/nas/projects/Perform-Hackathon-2026/services/blackjack/index.js` - Line 7
- `/mnt/nas/projects/Perform-Hackathon-2026/services/dashboard/dashboard.js` - Line 7
- `/mnt/nas/projects/Perform-Hackathon-2026/services/gateway/gateway.js` - Line 7

#### Broken Snippets:
```javascript
// ❌ INCORRECT PATHS (cause failures)
const { initializeTelemetry } = require('./common/opentelemetry');  // Frontend
const { initializeTelemetry } = require('./common/opentelemetry');  // Slots
const { initializeTelemetry } = require('./common/opentelemetry');  // Blackjack
const { initializeTelemetry } = require('./common/opentelemetry');  // Dashboard  
const { initializeTelemetry } = require('./services/common/opentelemetry');  // Gateway
```

#### Correct Fix:
```javascript
// ✅ CORRECT PATHS
const { initializeTelemetry } = require('../common/opentelemetry');  // All services
```

#### Root Cause:
- Frontend: References `./common/opentelemetry` but no common directory exists in `/services/frontend/`
- Other Services: Reference `./common/opentelemetry` but no common directory exists in individual service directories
- Only service with correct path: Roulette (uses `../common/opentelemetry`)

#### Expected Dynatrace Evidence:
- **Before Fix**: Services fail to start, no traces appear in Dynatrace
- **After Fix**: Services start successfully, traces flow from frontend → game services
- **Observable**: Missing service spans, broken trace propagation in service map

---

### 2. Missing/Wrong Service.name Resource
**Module**: M1 - Core Principles  
**Status**: ⚠️ PARTIALLY CONFIRMED - Secondary Effect of Import Failures

#### Files Affected:
- Services with import failures (see above) will never report proper service.name
- `/mnt/nas/projects/Perform-Hackathon-2026/services/common/opentelemetry.js` - Lines 16-32 (resource configuration is correct)

#### Broken Snippet:
```javascript
// Resource configuration in common/opentelemetry.js is CORRECT:
const resource = new Resource({
  [SemanticResourceAttributes.SERVICE_NAME]: serviceName,  // ✅ Properly configured
  // ... other attributes
});
```

#### Root Cause:
- The resource configuration itself is correct
- But services with broken imports won't start, so they won't report any service.name
- Results in "unknown_service" or missing service detection in Dynatrace

#### Expected Dynatrace Evidence:
- **Before Fix**: Services appear as "unknown" or don't appear in service inventory
- **After Fix**: Services appear with correct names (vegas-frontend-service, vegas-slots-service, etc.)
- **Observable**: Service inventory showing unnamed or unknown services

---

### 3. Logger Provider Not Wired → No Logs
**Module**: M1 - Core Principles  
**Status**: ✅ CONFIRMED - Systematic Logging Failure

#### Files Affected:
- `/mnt/nas/projects/Perform-Hackathon-2026/services/common/opentelemetry.js` - Lines 45-73 (SDK configuration)
- All Node.js services lack OpenTelemetry logging capabilities

#### Broken Snippet:
```javascript
// ❌ MISSING LOGGING PROVIDER IN SDK CONFIG
const sdk = new NodeSDK({
  resource,
  traceExporter: endpoint ? new OTLPTraceExporter({...}) : undefined,
  instrumentations: [getNodeAutoInstrumentations({...})],
  // ❌ NO loggerProvider configured
  // ❌ NO logRecordProcessor
  // ❌ NO logging exporter
});
```

#### Correct Fix:
```javascript
// ✅ ADD LOGGING PROVIDER TO SDK CONFIG
const sdk = new NodeSDK({
  resource,
  traceExporter: endpoint ? new OTLPTraceExporter({...}) : undefined,
  logRecordProcessor: new OTLPLogExporter(endpoint ? {...} : undefined),
  instrumentations: [
    getNodeAutoInstrumentations({...}),
    new LoggingInstrumentation(),  // Add logging instrumentation
  ],
});
```

#### Required Dependencies (add to all package.json):
```json
"dependencies": {
  "@opentelemetry/instrumentation-logging": "^0.35.0",
  "@opentelemetry/exporter-logs-otlp": "^0.41.0",
  // ... existing dependencies
}
```

#### Expected Dynatrace Evidence:
- **Before Fix**: No logs appear in Dynatrace Log Browser, only traces
- **After Fix**: Structured logs appear in Dynatrace with trace correlation
- **Observable**: Log volume metrics, log-based error detection, log events

---

### 4. Broken otel-config.yaml in Java Scoring Service
**Module**: M2 - SDK Configuration by File  
**Status**: ✅ CONFIRMED - Missing Declarative Configuration

#### Files Affected:
- `/mnt/nas/projects/Perform-Hackathon-2026/services/scoring/` - Missing otel-config.yaml
- `/mnt/nas/projects/Perform-Hackathon-2026/services/scoring/src/main/java/com/vegas/scoring/service/ScoringService.java` - Uses programmatic instead of declarative config

#### Broken Snippet:
```java
// ❌ CURRENT: Programmatic configuration (not zero-code)
@Autowired
@Qualifier("tracer")
private Tracer tracer;  // Manual dependency injection

// ✅ SHOULD BE: Declarative configuration (zero-code agent)
// File: src/main/resources/otel-config.yaml
```

#### Missing File: `src/main/resources/otel-config.yaml`
```yaml
# ✅ CORRECT: Declarative configuration that should exist
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryConfiguration
spec:
  resourceDetection:
    detectors: [env, host, process, container]
  propagators: [tracecontext, baggage]
  sampler:
    parentBased:
      root:
        traceIdRatioBased: 0.1  # 10% sampling rate
  processors:
    batch:
      sendBatchMaxSize: 1000
      timeout: 30s
  exporters:
    otlp:
      endpoint: "${OTEL_EXPORTER_OTLP_ENDPOINT:http://otel-collector:4317}"
      headers:
        authorization: "Api-Token ${DT_API_TOKEN}"
```

#### Expected Dynatrace Evidence:
- **Before Fix**: Java service traces appear but with missing resource attributes
- **After Fix**: Java service appears with proper semantic conventions, declarative configuration visible
- **Observable**: Resource attribute compliance, configuration validation status

---

### 5. Collector Processor Order Issues + Missing Memory Limiter
**Module**: M3 - Collector as Control Point  
**Status**: ⚠️ PARTIALLY CONFIRMED - Memory Limiter Present, Order May Need Adjustment

#### Files Affected:
- `/mnt/nas/projects/Perform-Hackathon-2026/codespace/manifests/otel-collector-statefulset-config.yaml` - Lines 138-255

#### Current Configuration:
```yaml
processors:
  batch:  # ❌ Should come after enrichment/transform
    send_batch_max_size: 1000
    timeout: 30s
    send_batch_size: 800
  memory_limiter:  # ✅ Correctly positioned first
    check_interval: 1s
    limit_percentage: 70
    spike_limit_percentage: 30
  cumulativetodelta: {}
  k8sattributes/k8S:  # ❌ Naming inconsistency
    extract:
      metadata:
        - k8s.cluster.uid
  k8sattributes:  # ✅ Good for Kubernetes enrichment
    extract:
      metadata:
        - k8s.pod.name
        - k8s.pod.uid
        # ... more attributes
  resource:  # ✅ Good resource attributes
    attributes:
      - key: k8s.cluster.name
        value: ${CLUSTERNAME}
        action: insert
  transform:  # ❌ Should come after enrichment
    error_mode: ignore
    # ... transform statements
```

#### Correct Order (Canonical: enrichment → filtering → aggregation → routing → export):
```yaml
processors:
  memory_limiter:  # ✅ Control plane first
    check_interval: 1s
    limit_percentage: 70
    spike_limit_percentage: 30
  k8sattributes:  # ✅ Enrichment
    extract:
      metadata:
        - k8s.pod.name
        - k8s.pod.uid
        # ... other attributes
  transform:  # ✅ Transformation after enrichment
    error_mode: ignore
    # ... transform statements
  batch:  # ✅ Aggregation last before export
    send_batch_max_size: 1000
    timeout: 30s
    send_batch_size: 800
```

#### Expected Dynatrace Evidence:
- **Before Fix**: Potential memory pressure, suboptimal processing order
- **After Fix**: Collector stability metrics, optimal processing performance
- **Observable**: Collector memory usage, processing throughput, error rates

---

### 6. Missing Routing/Enrichment → Raw YAML Sprawl
**Module**: M3 - Collector as Control Point  
**Status**: ✅ CONFIRMED - No Explicit Routing Configuration

#### Current Pipeline Configuration:
```yaml
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter,k8sattributes,transform,batch]  # ❌ No routing
      exporters: [spanmetrics,otlphttp]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter,transform,cumulativetodelta,batch]  # ❌ No routing
      exporters: [otlphttp]
    logs:
      receivers: [otlp]
      processors: [memory_limiter,k8sattributes,transform,resource,batch]  # ❌ No routing
      exporters: [otlphttp]
```

#### Missing Routing Configuration:
```yaml
# ✅ SHOULD ADD: Routing processors
processors:
  # ... existing processors ...
  routing/game_services:
    routes:
      - output: game_pipeline
        match:
          attributes:
            service.name: ["vegas-slots-service", "vegas-roulette-service", 
                          "vegas-dice-service", "vegas-blackjack-service"]
      - output: platform_pipeline  
        match:
          attributes:
            service.name: ["vegas-frontend-service", "vegas-dashboard-service", 
                          "vegas-scoring-service", "vegas-gateway-service"]

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter,k8sattributes,routing/game_services,transform,batch]
      exporters: [spanmetrics,otlphttp]
    
    game_pipeline:
      receivers: [otlp]
      processors: [memory_limiter,transform,batch]
      exporters: [otlphttp]
      
    platform_pipeline:
      receivers: [otlp] 
      processors: [memory_limiter,transform,batch]
      exporters: [otlphttp]
```

#### Expected Dynatrace Evidence:
- **Before Fix**: All telemetry mixed together, no separation of concerns
- **After Fix**: Separate views for game vs platform telemetry, improved filtering
- **Observable**: Pipeline separation, targeted analysis capabilities

---

### 7. Missing Tail Sampling + Spanmetrics
**Module**: M4 - Sampling Strategy  
**Status**: ✅ CONFIRMED - Connector Present But No Tail Sampling

#### Current Configuration:
```yaml
# ❌ ONLY CONNECTOR, NO TAIL SAMPLING PROCESSOR
connectors:
  spanmetrics:
    exemplars:
      enabled: true
    aggregation_temporality: "AGGREGATION_TEMPORALITY_DELTA"

# ❌ NO TAIL SAMPLING PROCESSOR
```

#### Missing Tail Sampling Configuration:
```yaml
# ✅ SHOULD ADD: Tail sampling processor
processors:
  tail_sampling:
    decisions:
      - from: service.name
        to: service.name
        # Keep error traces and slow traces
        sampling_percentage:
          - 100.0
            attributes:
              error: true
          - 100.0
            attributes:
              duration_ns: [>=, 1000000000]  # Keep traces > 1s
          - 10.0  # Sample remaining traces at 10%
            attributes:
              _underspecified_: true

# ✅ CONNECTOR CONFIGURATION IS CORRECT
connectors:
  spanmetrics:
    exemplars:
      enabled: true
    aggregation_temporality: "AGGREGATION_TEMPORALITY_DELTA"
```

#### Expected Dynatrace Evidence:
- **Before Fix**: High volume of traces, potential sampling costs, no span-based metrics
- **After Fix**: Reduced trace volume, spanmetrics visible, cost-effective sampling
- **Observable**: Trace sampling rates, spanmetrics connectors, RED metrics under sampling

---

## Module Validation Summary

| Module | Status | Defects Found | Fix Priority |
|--------|--------|---------------|--------------|
| **M1 - Core Principles** | ❌ **FAILED** | 3/3 defects confirmed | 🔴 **HIGH** |
| **M2 - SDK Configuration** | ❌ **FAILED** | 1/1 defect confirmed | 🔴 **HIGH** |
| **M3 - Collector Control Point** | ⚠️ **PARTIAL** | 2/3 defects confirmed | 🟡 **MEDIUM** |
| **M4 - Sampling Strategy** | ❌ **FAILED** | 1/1 defect confirmed | 🔴 **HIGH** |

## Next Steps

1. **Priority 1 (Critical)**: Fix import path defects in M1 services to enable basic telemetry
2. **Priority 2**: Add logger provider to OpenTelemetry SDK configuration
3. **Priority 3**: Implement declarative configuration for Java Scoring Service
4. **Priority 4**: Add routing and tail sampling to collector configuration

## Verification Checklist

- [ ] All services start successfully with correct import paths
- [ ] Logger provider configured and sending logs to Dynatrace
- [ ] Java service using declarative otel-config.yaml
- [ ] Collector has proper processor order and routing
- [ ] Tail sampling + spanmetrics configured and operational

---

*Generated: 2026-09-08*  
*Repository: https://github.com/dynatrace-oss/Perform-Hackathon-2026*  
*Training: Beyond the Honeymoon: OTel in Practice*