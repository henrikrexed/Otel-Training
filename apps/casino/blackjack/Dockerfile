FROM node:22-alpine

WORKDIR /app

# Copy service package.json
COPY blackjack/package*.json ./

# Install dependencies
RUN npm install --omit=dev

# Copy service files
COPY blackjack/ ./
# Copy common files into the app directory structure
RUN mkdir -p common && chmod 755 common
COPY common/service-runner.js ./common/service-runner.js
COPY common/opentelemetry.js ./common/opentelemetry.js
COPY common/propagators.js ./common/propagators.js
COPY common/openfeature.js ./common/openfeature.js
COPY common/redis.js ./common/redis.js
COPY common/scoring.js ./common/scoring.js
COPY common/logger.js ./common/logger.js
RUN chmod 644 ./common/*.js
# Copy proto files
RUN mkdir -p proto && chmod 755 proto
COPY proto/ ./proto/
RUN chmod -R 644 ./proto/*

# Expose ports
EXPOSE 8084 50054

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:8084/health', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"

# Start the service
CMD ["node", "index.js"]

