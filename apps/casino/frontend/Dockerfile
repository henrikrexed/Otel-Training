FROM node:22-alpine

WORKDIR /app

# Copy frontend service package.json
COPY frontend/package*.json ./

# Install dependencies
RUN npm install --omit=dev

# Copy frontend service files (includes public folder)
COPY frontend/ ./
# Copy common files into the app directory structure
RUN mkdir -p common && chmod 755 common
COPY common/openfeature.js ./common/openfeature.js
COPY common/opentelemetry.js ./common/opentelemetry.js
COPY common/propagators.js ./common/propagators.js
COPY common/logger.js ./common/logger.js
COPY common/pii.js ./common/pii.js
COPY common/casino-metrics.js ./common/casino-metrics.js
RUN chmod 644 ./common/*.js
COPY proto/ ./proto/

# Expose port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/health', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"

# Start the frontend service
CMD ["node", "frontend-service.js"]

