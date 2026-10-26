# Capstone 1 - The Voting App
# Result Service - Node.js 20
# Hardened multi-stage build with pinned SHA256 base images

# =========================================================================
# Stage 1: Build dependencies
# =========================================================================
FROM node:20-alpine@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293 AS builder

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install production dependencies only
RUN npm install --omit=dev --ignore-scripts && \
    npm cache clean --force

# =========================================================================
# Stage 2: Production runtime
# =========================================================================
FROM node:20-alpine@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293 AS runtime

# Install runtime dependencies
RUN apk add --no-cache \
    curl \
    netcat-openbsd \
    postgresql-client \
    && rm -rf /var/cache/apk/*

# Use existing 'node' user (UID 1000, GID 1000) from base image
WORKDIR /app

# Copy node_modules from builder
COPY --from=builder --chown=node:node /app/node_modules ./node_modules

# Copy application code
COPY --chown=node:node server.js .

# Copy public assets
COPY --chown=node:node public ./public

# Security hardening
USER node
ENV NODE_ENV=production \
    NODE_OPTIONS="--no-warnings"

# Expose port (non-root: unprivileged port 8080)
EXPOSE 8080

# Health check
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=5 \
    CMD curl -f http://localhost:8080/health || exit 1

# Run application
CMD ["node", "server.js"]