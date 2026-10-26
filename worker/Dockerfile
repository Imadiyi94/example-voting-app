# Capstone 1 - The Voting App
# Worker Service - .NET Core 8.0
# Hardened multi-stage build with pinned SHA256 base images

# =========================================================================
# Stage 1: Build
# =========================================================================
FROM mcr.microsoft.com/dotnet/sdk:8.0@sha256:738f72aff955d5c5690e06b6fc8ecd1b90ead564099a257ac528ff720b8da85f AS builder

WORKDIR /src

# Copy project file and restore dependencies with RuntimeIdentifier
COPY Worker.csproj .
RUN dotnet restore Worker.csproj -r linux-x64

# Copy source and build
COPY . .
RUN dotnet publish Worker.csproj -c Release -o /app/publish --no-restore -r linux-x64

# =========================================================================
# Stage 2: Runtime
# =========================================================================
FROM mcr.microsoft.com/dotnet/runtime:8.0-alpine@sha256:ccab58874124680f5dd4539c425b532cd6ad6e364c71b8a10dc9c5c1fabb4089 AS runtime

# Install runtime dependencies
RUN apk add --no-cache \
    curl \
    netcat-openbsd \
    postgresql-client \
    && rm -rf /var/cache/apk/*

# Create non-root user
RUN addgroup -g 1000 -S appgroup && \
    adduser -u 1000 -S -G appgroup -h /app -s /sbin/nologin appuser

# Set working directory
WORKDIR /app

# Copy published application from builder
COPY --from=builder --chown=appuser:appgroup /app/publish .

# Security hardening
USER appuser
ENV DOTNET_EnableDiagnostics=0 \
    DOTNET_GCDebug=0

# Health check - verify connectivity to Redis and PostgreSQL
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
    CMD nc -z redis 6379 && nc -z db 5432 || exit 1

# Run the worker
ENTRYPOINT ["dotnet", "Worker.dll"]