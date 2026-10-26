# Capstone 1 - The Voting App
## Local Development Guide

This guide covers running the complete 5-service voting application stack locally using Docker Compose.

---

## Prerequisites

- **Docker Engine** 24.0+
- **Docker Compose** v2.20+ (as `docker compose` plugin)
- **4GB+ RAM** available for containers
- **Ports 5000, 5001** free on host

---

## Quick Start

```bash
# Navigate to project directory
cd example-voting-app

# Start all services
docker compose up -d

# Verify all services are healthy
docker compose ps

# View logs
docker compose logs -f
```

---

## Service Access

| Service | URL | Description |
|---------|-----|-------------|
| **Vote** | http://localhost:5000 | Cast votes (Cats vs Dogs) |
| **Result** | http://localhost:5001 | Real-time results dashboard |

---

## Architecture Overview

```
┌─────────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
│   Vote      │────▶│  Redis  │────▶│ Worker  │────▶│   DB    │◀───▶│ Result  │
│  (Flask)    │     │ (Queue) │     │ (.NET)  │     │(Postgres)│     │ (Node)  │
│  :5000      │     │  :6379  │     │         │     │  :5432  │     │  :5001  │
└─────────────┘     └─────────┘     └─────────┘     └─────────┘     └─────────┘
       │                                                                    
       └─────────────────────── voting-net (bridge) ──────────────────────┘
```

---

## Network & Volumes

### Network
- **Name**: `voting-net` (bridge)
- **Scope**: All 5 services communicate via service names
- **External Access**: Vote (5000) and Result (5001) exposed to host

### Volumes
| Volume | Mount Point | Purpose |
|--------|-------------|---------|
| `voting-app-db-data` | `/var/lib/postgresql/data` | Persistent PostgreSQL data |
| `voting-app-redis-data` | `/data` | Redis AOF persistence |

---

## Security Features

All containers run with:
- **Non-root user** (UID 1000, GID 1000)
- **Read-only root filesystem**
- **Dropped capabilities** (`CAP_DROP: ALL`)
- **No privilege escalation** (`no-new-privileges:true`)
- **tmpfs** for `/tmp` and `/var/run`

Secrets managed via Docker secrets:
- `db_password` → `./secrets/db_password.txt`

---

## Verification Checklist

After `docker compose up -d`, verify:

```bash
# 1. All containers running
docker compose ps
# Expected: 5 containers, all "Up" with "healthy" status

# 2. Health endpoints
curl -f http://localhost:5000/health   # Vote service
curl -f http://localhost:5001/health   # Result service

# 3. Vote flow test
# Open http://localhost:5000 in browser
# Click "Cats" or "Dogs"
# Open http://localhost:5001 in another tab
# Verify real-time update appears

# 4. Database persistence
docker compose down
docker compose up -d
# Previous votes should still appear in Results
```

---

## Common Operations

### View Logs
```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f vote
docker compose logs -f worker
docker compose logs -f db
```

### Restart Single Service
```bash
docker compose restart vote
```

### Rebuild After Code Changes
```bash
docker compose build vote
docker compose up -d vote
```

### Full Reset (Wipes Database)
```bash
docker compose down -v
docker compose up -d
```

### Inspect Container
```bash
docker compose exec vote sh
docker compose exec db psql -U postgres -d postgres
docker compose exec redis redis-cli
```

---

## Troubleshooting

### Port Already in Use
```bash
# Check what's using ports 5000/5001
lsof -i :5000
lsof -i :5001

# Or change ports in docker-compose.yml
ports:
  - "5000:80"  # Change 5000 to another port
```

### Container Fails Health Check
```bash
# Check container logs
docker compose logs vote

# Check health check command manually
docker compose exec vote curl -f http://localhost:80/
```

### Database Connection Issues
```bash
# Verify DB is ready
docker compose exec db pg_isready -U postgres

# Check worker logs for DB connection
docker compose logs worker
```

### Redis Connection Issues
```bash
# Test Redis connectivity
docker compose exec redis redis-cli ping

# Check vote/worker logs
docker compose logs vote
docker compose logs worker
```

### Permission Denied (Secrets)
```bash
# Ensure secrets file exists and is readable
ls -la secrets/
cat secrets/db_password.txt

# Fix permissions if needed
chmod 600 secrets/db_password.txt
```

---

## Resource Limits

Default resource constraints (adjust in `docker-compose.yml`):

| Service | CPU Limit | Memory Limit | CPU Reserve | Memory Reserve |
|---------|-----------|--------------|-------------|----------------|
| vote    | 0.5       | 256M         | 0.1         | 64M            |
| redis   | 0.25      | 256M         | 0.05        | 64M            |
| worker  | 0.5       | 512M         | 0.1         | 128M           |
| db      | 0.5       | 512M         | 0.1         | 128M           |
| result  | 0.5       | 256M         | 0.1         | 64M            |

---

## Development Workflow

1. **Make code changes** in `vote/app.py`, `worker/Program.cs`, or `result/server.js`
2. **Rebuild affected service**: `docker compose build <service>`
3. **Restart service**: `docker compose up -d <service>`
4. **Test changes** at localhost:5000 / localhost:5001
5. **Run tests** (when implemented): `docker compose run --rm <service> test`

---

## Next Steps (Phase 2+)

- **Phase 2**: Replace base images with pinned SHA256 digests, add Trivy scanning
- **Phase 3**: Terraform → EKS cluster provisioning
- **Phase 4**: GitHub Actions CI/CD pipeline
- **Phase 5**: Helm charts for Kubernetes deployment

---

## File Structure

```
example-voting-app/
├── docker-compose.yml          # Main orchestration
├── .dockerignore               # Build context exclusions
├── secrets/
│   └── db_password.txt         # Database password (Docker secret)
├── db/
│   └── init.sql                # Database initialization
├── vote/
│   ├── Dockerfile              # Multi-stage Python build
│   ├── requirements.txt        # Python dependencies
│   └── app.py                  # Flask application
├── worker/
│   ├── Dockerfile              # Multi-stage .NET build
│   ├── Worker.csproj           # Project file
│   └── Program.cs              # Background worker
└── result/
    ├── Dockerfile              # Multi-stage Node.js build
    ├── package.json            # Node dependencies
    ├── server.js               # Express + SSE server
    └── public/
        └── index.html          # Results dashboard
```

---

## Support

For issues with the local stack, check:
1. Docker Desktop is running (Windows/Mac)
2. Sufficient resources allocated (4GB+ RAM)
3. No conflicting services on ports 5000, 5001, 5432, 6379