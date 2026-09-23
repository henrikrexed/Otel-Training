# Source Code Locations

## Overview

The Vegas Casino application consists of multiple microservices, each in its own directory. This guide explains where to find the source code for each service and how to make changes.

!!! info "Repository Structure"
    All source code is located in the `services/` directory. Each service has its own subdirectory with language-specific implementations.

## Service Directory Structure

```
services/
├── frontend/          # Frontend web UI (Node.js/Express)
├── slots/            # Slots game service (Node.js)
├── roulette/         # Roulette game service (Python + Node.js)
├── dice/             # Dice game service (Go)
├── blackjack/        # Blackjack game service (Node.js)
├── scoring/          # Scoring service (Java/Spring Boot)
├── dashboard/        # Dashboard service (Node.js)
├── gateway/          # API Gateway service (Node.js)
├── common/           # Shared utilities and libraries
└── grpc/             # Generated gRPC code
```

## Services Overview

| Service | Location | Technology | Port | Purpose |
|---------|----------|------------|------|---------|
| **Frontend** | `services/frontend/` | Node.js/Express | 3000 | Web UI for players |
| **Slots** | `services/slots/` | Node.js | 50051 (gRPC) | Slots game logic |
| **Roulette** | `services/roulette/` | Python | 50052 (gRPC) | Roulette game logic |
| **Dice** | `services/dice/` | Go | 50053 (gRPC) | Dice game logic |
| **Blackjack** | `services/blackjack/` | Node.js | 50054 (gRPC) | Blackjack game logic |
| **Scoring** | `services/scoring/` | Java/Spring Boot | 8085 (HTTP) | Leaderboards & statistics |
| **Dashboard** | `services/dashboard/` | Node.js | 50055 (gRPC) | Analytics dashboard |
| **Gateway** | `services/gateway/` | Node.js | - | API Gateway |

## Service Details

### Frontend Service

**Location**: `services/frontend/`

**Technology**: :material-language-javascript: Node.js/Express

**Key Files**:
- `index.js` - Main server file
- `public/` - Static HTML/CSS/JS files
- `package.json` - Dependencies

**Purpose**: Web UI for players to interact with games

---

### Game Services

#### :material-dice-1: Slots Service

**Location**: `services/slots/`

**Technology**: :material-language-javascript: Node.js

**Key Files**:
- `slots-service.js` - Main service implementation
- `slots-service-grpc.js` - gRPC server
- `index.js` - Entry point

#### :material-dice-2: Roulette Service

**Location**: `services/roulette/`

**Technology**: :material-language-python: Python (primary) + :material-language-javascript: Node.js (legacy)

**Key Files**:
- `python/roulette_service_grpc.py` - Main Python gRPC service
- `python/roulette_service.py` - HTTP service (legacy)
- `roulette-service.js` - Node.js implementation (legacy)

#### :material-dice-3: Dice Service

**Location**: `services/dice/`

**Technology**: :material-language-go: Go

**Key Files**:
- `go/dice-service.go` - Main service implementation
- `go/go.mod` - Go dependencies

#### :material-cards: Blackjack Service

**Location**: `services/blackjack/`

**Technology**: :material-language-javascript: Node.js

**Key Files**:
- `blackjack-service.js` - Main service implementation
- `blackjack-service-grpc.js` - gRPC server

---

### Supporting Services

#### :material-trophy: Scoring Service

**Location**: `services/scoring/`

**Technology**: :material-language-java: Java/Spring Boot

**Key Files**:
- `src/main/java/` - Java source code
- `pom.xml` - Maven dependencies

#### :material-chart-line: Dashboard Service

**Location**: `services/dashboard/`

**Technology**: :material-language-javascript: Node.js

**Key Files**:
- `dashboard-service.js` - Main service implementation
- `public/dashboard.html` - Dashboard UI

---

### Common Utilities

**Location**: `services/common/`

**Contains**:
- `logger.js` / `logger.py` - Logging utilities
- `opentelemetry.js` / `opentelemetry_setup.py` - OpenTelemetry setup
- `openfeature.js` / `featureflags.py` - Feature flag integration
- `redis.js` / `redis_helper.py` - Redis helpers
- `scoring.js` / `scoring_helper.py` - Scoring service integration

## Making Changes

### Step 1: Edit Source Code

Navigate to the appropriate service directory and edit the source files:

```bash
# Example: Edit slots service
cd services/slots
vim slots-service.js

# Example: Edit roulette service (Python)
cd services/roulette/python
vim roulette_service_grpc.py
```

### Step 2: Commit and Push Changes

After making changes, commit and push to your forked repository:

```bash
# Stage changes
git add services/slots/slots-service.js

# Commit with descriptive message
git commit -m "Improve OpenTelemetry instrumentation in slots service"

# Push to your fork
git push origin main
```

### Step 3: GitHub Actions Builds Images

When you push changes, GitHub Actions automatically:

1. ✅ Detects changes in service directories
2. ✅ Builds Docker images for modified services
3. ✅ Pushes images to GitHub Container Registry (GHCR)
4. ✅ Tags images with commit SHA and branch name

**Workflow**: `.github/workflows/docker-build.yml`

!!! tip "Automatic Builds"
    You don't need to build images manually! GitHub Actions handles everything automatically when you push code changes.

### Step 4: Update Helm Deployment

After images are built, update your Helm deployment to use the new images:

See [Updating with Helm](helm-updates.md) for detailed instructions.

## OpenTelemetry Instrumentation

All services include OpenTelemetry instrumentation. To improve instrumentation:

=== "Node.js Services"

    **Location**: `services/common/opentelemetry.js`

    **Key Functions**:
    - `initializeTelemetry()` - Sets up OpenTelemetry
    - `createSpan()` - Creates custom spans
    - `addAttributes()` - Adds attributes to spans

    **Example**:
    ```javascript
    const { createSpan, addAttributes } = require('../common/opentelemetry');

    // Create a span
    const span = createSpan('game-logic', tracer);

    // Add attributes
    addAttributes(span, {
      'game.type': 'slots',
      'bet.amount': betAmount,
      'game.result': result
    });

    // End span
    span.end();
    ```

=== "Python Services"

    **Location**: `services/roulette/python/opentelemetry_setup.py`

    **Key Functions**:
    - `initialize_telemetry()` - Sets up OpenTelemetry
    - `add_game_attributes()` - Adds game-specific attributes

    **Example**:
    ```python
    from opentelemetry_setup import initialize_telemetry, add_game_attributes

    tracer = initialize_telemetry("vegas-roulette-service", metadata)

    with tracer.start_as_current_span("game-logic") as span:
        add_game_attributes(span, {
            'game.type': 'roulette',
            'bet.amount': bet_amount,
            'game.result': result
        })
    ```

=== "Go Services"

    **Location**: `services/dice/go/dice-service.go`

    **Example**:
    ```go
    ctx, span := tracer.Start(ctx, "game-logic")
    defer span.End()

    span.SetAttributes(
        attribute.String("game.type", "dice"),
        attribute.Int("bet.amount", betAmount),
        attribute.String("game.result", result),
    )
    ```

## Feature Flag Integration

Services use feature flags via OpenFeature. See [Feature Flags Guide](feature-flags.md) for details.

## Testing Changes Locally

!!! note "Local Testing"
    While you can't build images locally in the hackathon environment, you can test code logic:

```bash
# For Node.js services
cd services/slots
node slots-service.js

# For Python services
cd services/roulette/python
python3 roulette_service_grpc.py

# For Go services
cd services/dice/go
go run dice-service.go
```

## Next Steps

- [:octicons-arrow-right-24: GitHub Actions Workflow](github-actions.md): Understand how images are built
- [:octicons-arrow-right-24: Updating with Helm](helm-updates.md): Learn how to deploy changes
- [:octicons-arrow-right-24: Feature Flags Guide](feature-flags.md): Understand feature flag integration
