#!/usr/bin/env bash
###############################################################################
# Production‑grade PostgreSQL HA stack (Percona‑Patroni) on Docker‑Compose
# Optimized for 1M users with minimal resource usage
# Author : Ali‑Dadmand‑ready template
# Version: 2.0 – 2025‑01‑27
###############################################################################
set -euo pipefail

### --------------------------------------------------------------------------
### 0. Prerequisites & System Checks
### --------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || {
  echo "[INFO] Docker not found – installing...";
  curl -fsSL https://get.docker.com | sh
}
command -v docker compose >/dev/null 2>&1 || {
  echo "[INFO] Docker Compose v2 not found – installing...";
  DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
  mkdir -p "$DOCKER_CONFIG/cli-plugins"
  
  # Detect architecture and OS for correct binary
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    if [[ $(uname -m) == "arm64" ]]; then
      COMPOSE_ARCH="darwin-arm64"
    else
      COMPOSE_ARCH="darwin-amd64"
    fi
  else
    # Linux
    COMPOSE_ARCH="linux-$(uname -m)"
  fi
  
  curl -fsSL "https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-${COMPOSE_ARCH}" \
       -o "$DOCKER_CONFIG/cli-plugins/docker-compose"
  chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"
}

# Check system resources
echo "[INFO] Checking system resources..."

# Detect OS and get system resources
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS
  TOTAL_MEM=$(sysctl -n hw.memsize | awk '{print int($1/1024/1024)}')
  TOTAL_CPU=$(sysctl -n hw.ncpu)
  echo "[INFO] macOS detected"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
  # Linux
  TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
  TOTAL_CPU=$(nproc)
  echo "[INFO] Linux detected"
else
  # Fallback for other systems
  TOTAL_MEM=8192  # Default to 8GB
  TOTAL_CPU=4     # Default to 4 cores
  echo "[INFO] Unknown OS, using default values"
fi

echo "[INFO] System has ${TOTAL_MEM}MB RAM and ${TOTAL_CPU} CPU cores"

if [ "$TOTAL_MEM" -lt 4096 ]; then
  echo "[WARNING] Less than 4GB RAM detected. Performance may be limited."
fi

### --------------------------------------------------------------------------
### 1. Passwords & cluster variables
### --------------------------------------------------------------------------
export WORKDIR=./pg-ha
export CLUSTER_NAME=prod_pg_cluster
export NET_NAME=pgnet
export POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-$(openssl rand -base64 32)}
export REPLICATION_PASSWORD=${REPLICATION_PASSWORD:-$(openssl rand -base64 32)}
export CHECK_PASSWORD=${CHECK_PASSWORD:-$(openssl rand -base64 32)}
export POOL_PASSWORD=${POOL_PASSWORD:-$(openssl rand -base64 32)}
export ETCD_CLUSTER="etcd1=http://etcd1:2380,etcd2=http://etcd2:2380,etcd3=http://etcd3:2380"
# etcd CLIENT ports (2379) for Patroni – peer ports (2380) are only for etcd itself
export ETCD_CLIENTS="etcd1:2379,etcd2:2379,etcd3:2379"
# Basic auth header for Patroni REST API checks (haproxy/prometheus/healthcheck)
export PATRONI_BASIC_AUTH=$(printf 'patroni:%s' "${CHECK_PASSWORD}" | base64 | tr -d '\n')
# Password percent-encoded for use inside a postgres DSN URI (base64 has / and =)
export CHECK_PASSWORD_ENC=$(python3 -c 'import urllib.parse,os;print(urllib.parse.quote(os.environ["CHECK_PASSWORD"],safe=""))')

# Calculate resource limits based on available system resources
export PG_MEM_LIMIT=${PG_MEM_LIMIT:-$((TOTAL_MEM / 4))}M
export ETCD_MEM_LIMIT=${ETCD_MEM_LIMIT:-256M}
export HAPROXY_MEM_LIMIT=${HAPROXY_MEM_LIMIT:-128M}
export PGBOUNCER_MEM_LIMIT=${PGBOUNCER_MEM_LIMIT:-256M}

mkdir -p "$WORKDIR"/{config,logs,data,backups}
cd "$WORKDIR"

### --------------------------------------------------------------------------
### 2. .env file for Docker Compose variable interpolation
### --------------------------------------------------------------------------
cat > .env <<"EOF"
# ---------------------------------------------------------------------------
# Auto‑generated – do not edit manually; change via environment then re‑run.
# ---------------------------------------------------------------------------
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REPLICATION_PASSWORD=${REPLICATION_PASSWORD}
CHECK_PASSWORD=${CHECK_PASSWORD}
POOL_PASSWORD=${POOL_PASSWORD}
CLUSTER_NAME=${CLUSTER_NAME}
ETCD_CLUSTER=${ETCD_CLUSTER}
PG_MEM_LIMIT=${PG_MEM_LIMIT}
ETCD_MEM_LIMIT=${ETCD_MEM_LIMIT}
HAPROXY_MEM_LIMIT=${HAPROXY_MEM_LIMIT}
PGBOUNCER_MEM_LIMIT=${PGBOUNCER_MEM_LIMIT}
EOF
envsubst < .env > .env.tmp && mv .env.tmp .env

### --------------------------------------------------------------------------
### 3. HAProxy configuration (optimized for high concurrency)
### --------------------------------------------------------------------------
cat > config/haproxy.cfg <<'EOF'
global
  maxconn 10000
  log stdout format raw local0
  tune.ssl.default-dh-param 2048
  tune.bufsize 32768
  tune.maxrewrite 8192

defaults
  mode tcp
  timeout connect 3s
  timeout client 30m
  timeout server 30m
  timeout check 5s
  option log-health-checks
  option redispatch
  retries 3

# ---------------------------------------------------------------------------
# RW traffic – clients connect here for reads *and* writes
# ---------------------------------------------------------------------------
listen postgres_rw
  bind *:5432
  balance roundrobin
  # /primary returns 200 only on the leader – writes MUST hit the primary
  option httpchk
  http-check send meth GET uri /primary ver HTTP/1.1 hdr Authorization "Basic ${PATRONI_BASIC_AUTH}"
  http-check expect status 200
  default-server inter 2s fall 3 rise 2 on-marked-down shutdown-sessions
  server patroni1 patroni1:5432 check port 8008
  server patroni2 patroni2:5432 check port 8008
  server patroni3 patroni3:5432 check port 8008

# ---------------------------------------------------------------------------
# RO traffic – read‑only queries routed to standbys
# ---------------------------------------------------------------------------
listen postgres_ro
  bind *:5433
  balance roundrobin
  # /replica returns 200 only on standbys
  option httpchk
  http-check send meth GET uri /replica ver HTTP/1.1 hdr Authorization "Basic ${PATRONI_BASIC_AUTH}"
  http-check expect status 200
  default-server inter 2s fall 3 rise 2 on-marked-down shutdown-sessions
  server patroni1 patroni1:5432 check port 8008
  server patroni2 patroni2:5432 check port 8008
  server patroni3 patroni3:5432 check port 8008

# ---------------------------------------------------------------------------
# Stats UI (with basic auth for security)
# ---------------------------------------------------------------------------
listen stats
  bind *:7001
  mode http
  stats enable
  stats uri /
  stats refresh 10s
  stats auth admin:${CHECK_PASSWORD}
  stats admin if TRUE

# Prometheus exporter endpoint (built into HAProxy 2.x)
listen metrics
  bind *:8404
  mode http
  http-request use-service prometheus-exporter if { path /metrics }
EOF
envsubst < config/haproxy.cfg > config/haproxy.cfg.tmp && mv config/haproxy.cfg.tmp config/haproxy.cfg

### --------------------------------------------------------------------------
### 4. Patroni runtime image (pip-installed Patroni on top of Percona PG 17)
### --------------------------------------------------------------------------
# The stock percona/percona-distribution-postgresql image is plain PostgreSQL.
# Multi-stage build: install Patroni + psycopg2 on python:3.9-slim, then copy
# into the Percona image (matches its python3.9).
cat > config/Dockerfile <<'EOF'
FROM python:3.9-slim AS builder
RUN pip install --no-cache-dir --prefix=/install "patroni[etcd3]~=4.0" "psycopg2-binary>=2.9.9"

FROM percona/percona-distribution-postgresql:17.5-2
# Base image defaults to USER postgres – switch back for the install steps
USER root
COPY --from=builder /install /usr/local
COPY patroni-entrypoint.sh /usr/local/bin/patroni-entrypoint.sh
# Fix shebangs (builder python lives at /usr/local/bin/python; this image's is /usr/bin/python3)
RUN chmod +x /usr/local/bin/patroni-entrypoint.sh \
 && sed -i '1s|^.*$|#!/usr/bin/python3|' /usr/local/bin/patroni /usr/local/bin/patronictl \
 && mkdir -p /data/db \
 && chown postgres:root /data/db \
 && chmod 700 /data/db \
 && mkdir -p /home/postgres \
 && chown postgres:root /home/postgres \
 && chmod 750 /home/postgres
ENV PYTHONPATH=/usr/local/lib/python3.9/site-packages
ENV PATH=/usr/pgsql-17/bin:/usr/local/bin:${PATH}
ENTRYPOINT ["/usr/local/bin/patroni-entrypoint.sh"]
EOF

cat > config/patroni-entrypoint.sh <<'EOF'
#!/bin/sh
set -e

DATA_DIR="/data/db"
mkdir -p "$DATA_DIR" 2>/dev/null || true

# Patroni refuses to run as root – drop to postgres via gosu
if [ "$(id -u)" = "0" ]; then
  chown postgres:root "$DATA_DIR" 2>/dev/null || true
  chmod 700 "$DATA_DIR" 2>/dev/null || true
  exec gosu postgres "/usr/local/bin/patroni-entrypoint.sh"
fi

exec patroni /etc/patroni.yml
EOF
chmod +x config/patroni-entrypoint.sh

### --------------------------------------------------------------------------
### 5. Shared Patroni bootstrap YAML snippet (optimized for 1M users)
### --------------------------------------------------------------------------
generate_patroni_yaml () {
  local name="$1"; local host="$2"
  cat > "config/${name}.yml" <<EOF
scope: ${CLUSTER_NAME}
name: ${name}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${host}:8008
  authentication:
    username: patroni
    password: ${CHECK_PASSWORD}

# Patroni must use the etcd3 (gRPC) API – etcd 3.5 has the v2 API disabled.
# Hosts are plain host:clientport (client port 2379, NOT the 2380 peer port).
etcd3:
  hosts: ${ETCD_CLIENTS}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        # Connection settings
        max_connections: 2000
        superuser_reserved_connections: 10
        
        # Memory settings (optimized for minimal resources)
        shared_buffers: 1GB
        effective_cache_size: 3GB
        work_mem: 4MB
        maintenance_work_mem: 256MB
        
        # WAL settings
        wal_level: replica
        wal_buffers: 16MB
        max_wal_senders: 10
        max_replication_slots: 10
        hot_standby: "on"
        
        # Checkpoint settings
        checkpoint_completion_target: 0.9
        wal_compression: "on"
        max_wal_size: 2GB
        min_wal_size: 1GB
        
        # Query optimization
        random_page_cost: 1.1
        effective_io_concurrency: 200
        default_statistics_target: 100
        
        # Logging
        log_statement: "none"
        log_min_duration_statement: 1000
        log_checkpoints: "on"
        log_connections: "on"
        log_disconnections: "on"
        log_lock_waits: "on"
        log_temp_files: 0
        
        # Autovacuum
        autovacuum: "on"
        autovacuum_max_workers: 3
        autovacuum_naptime: 60
        autovacuum_vacuum_scale_factor: 0.1
        autovacuum_analyze_scale_factor: 0.05
        
        # Replication
        max_replication_slots: 10
        wal_keep_size: 1024
        
        # Security
        ssl: "off"
        password_encryption: "scram-sha-256"
        
        # Performance
        synchronous_commit: "on"
        fsync: "on"
        full_page_writes: "on"
        
        # Connection pooling
        tcp_keepalives_idle: 600
        tcp_keepalives_interval: 30
        tcp_keepalives_count: 3
        
  initdb:
    - encoding: UTF8
    - locale: C.utf8
    - data-checksums
  pg_hba:
    - local all all trust
    - host all all 0.0.0.0/0 md5
    - host replication replicator 0.0.0.0/0 md5
    - host all haproxy_check 0.0.0.0/0 md5
    - host all pooler 0.0.0.0/0 md5

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${host}:5432
  data_dir: /data/db
  bin_dir: /usr/pgsql-17/bin
  authentication:
    superuser:
      username: postgres
      password: ${POSTGRES_PASSWORD}
    replication:
      username: replicator
      password: ${REPLICATION_PASSWORD}
  parameters:
    wal_compression: "on"
    log_statement: "none"
    log_min_duration_statement: 1000
EOF
}
generate_patroni_yaml patroni1 patroni1
generate_patroni_yaml patroni2 patroni2
generate_patroni_yaml patroni3 patroni3

### --------------------------------------------------------------------------
### 6. Docker‑Compose file (with resource limits)
### --------------------------------------------------------------------------
cat > docker-compose.yml <<'EOF'

networks:
  pgnet:
    name: ${NET_NAME}
    driver: bridge

volumes:
  pgdata1:
    driver: local
  pgdata2:
    driver: local
  pgdata3:
    driver: local
  etcd_data1:
    driver: local
  etcd_data2:
    driver: local
  etcd_data3:
    driver: local
  prometheus_data:
    driver: local
  grafana_data:
    driver: local

services:

  # -------------------------------------------------------------------------
  # Distributed Configuration Store – etcd (3 nodes for quorum)
  # -------------------------------------------------------------------------
  etcd1:
    image: bitnamilegacy/etcd:3.5.9
    hostname: etcd1
    networks: [pgnet]
    volumes:
      - etcd_data1:/etcd-data
    environment:
      ETCD_NAME: etcd1
      ETCD_INITIAL_CLUSTER: ${ETCD_CLUSTER}
      ETCD_INITIAL_CLUSTER_STATE: new
      ETCD_LISTEN_PEER_URLS: http://0.0.0.0:2380
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_ADVERTISE_CLIENT_URLS: http://etcd1:2379
      ETCD_ADVERTISE_PEER_URLS: http://etcd1:2380
      ETCD_DATA_DIR: /etcd-data
      ALLOW_NONE_AUTHENTICATION: "yes"
    deploy:
      resources:
        limits:
          memory: ${ETCD_MEM_LIMIT}
          cpus: '0.5'
        reservations:
          memory: 128M
          cpus: '0.1'
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 10s
      timeout: 5s
      retries: 3

  etcd2:
    image: bitnamilegacy/etcd:3.5.9
    hostname: etcd2
    networks: [pgnet]
    volumes:
      - etcd_data2:/etcd-data
    environment:
      ETCD_NAME: etcd2
      ETCD_INITIAL_CLUSTER: ${ETCD_CLUSTER}
      ETCD_INITIAL_CLUSTER_STATE: new
      ETCD_LISTEN_PEER_URLS: http://0.0.0.0:2380
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_ADVERTISE_CLIENT_URLS: http://etcd2:2379
      ETCD_ADVERTISE_PEER_URLS: http://etcd2:2380
      ETCD_DATA_DIR: /etcd-data
      ALLOW_NONE_AUTHENTICATION: "yes"
    deploy:
      resources:
        limits:
          memory: ${ETCD_MEM_LIMIT}
          cpus: '0.5'
        reservations:
          memory: 128M
          cpus: '0.1'
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 10s
      timeout: 5s
      retries: 3

  etcd3:
    image: bitnamilegacy/etcd:3.5.9
    hostname: etcd3
    networks: [pgnet]
    volumes:
      - etcd_data3:/etcd-data
    environment:
      ETCD_NAME: etcd3
      ETCD_INITIAL_CLUSTER: ${ETCD_CLUSTER}
      ETCD_INITIAL_CLUSTER_STATE: new
      ETCD_LISTEN_PEER_URLS: http://0.0.0.0:2380
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_ADVERTISE_CLIENT_URLS: http://etcd3:2379
      ETCD_ADVERTISE_PEER_URLS: http://etcd3:2380
      ETCD_DATA_DIR: /etcd-data
      ALLOW_NONE_AUTHENTICATION: "yes"
    deploy:
      resources:
        limits:
          memory: ${ETCD_MEM_LIMIT}
          cpus: '0.5'
        reservations:
          memory: 128M
          cpus: '0.1'
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 10s
      timeout: 5s
      retries: 3

  # -------------------------------------------------------------------------
  # Patroni‑managed PostgreSQL nodes
  # -------------------------------------------------------------------------
  patroni1:
    build:
      context: ./config
      dockerfile: Dockerfile
    image: pg-ha-patroni:pg17-local
    hostname: patroni1
    networks: [pgnet]
    depends_on:
      etcd1:
        condition: service_healthy
      etcd2:
        condition: service_healthy
      etcd3:
        condition: service_healthy
    volumes:
      - pgdata1:/data/db
      - ./config/patroni1.yml:/etc/patroni.yml:ro
      - ./logs:/var/log/postgresql
    environment:
      PATRONI_CONFIG_PATH: /etc/patroni.yml
    deploy:
      resources:
        limits:
          memory: ${PG_MEM_LIMIT}
          cpus: '2.0'
        reservations:
          memory: 1G
          cpus: '0.5'
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -fsu patroni:${CHECK_PASSWORD} http://localhost:8008/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s

  patroni2:
    build:
      context: ./config
      dockerfile: Dockerfile
    image: pg-ha-patroni:pg17-local
    hostname: patroni2
    networks: [pgnet]
    depends_on:
      etcd1:
        condition: service_healthy
      etcd2:
        condition: service_healthy
      etcd3:
        condition: service_healthy
    volumes:
      - pgdata2:/data/db
      - ./config/patroni2.yml:/etc/patroni.yml:ro
      - ./logs:/var/log/postgresql
    environment:
      PATRONI_CONFIG_PATH: /etc/patroni.yml
    deploy:
      resources:
        limits:
          memory: ${PG_MEM_LIMIT}
          cpus: '2.0'
        reservations:
          memory: 1G
          cpus: '0.5'
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -fsu patroni:${CHECK_PASSWORD} http://localhost:8008/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s

  patroni3:
    build:
      context: ./config
      dockerfile: Dockerfile
    image: pg-ha-patroni:pg17-local
    hostname: patroni3
    networks: [pgnet]
    depends_on:
      etcd1:
        condition: service_healthy
      etcd2:
        condition: service_healthy
      etcd3:
        condition: service_healthy
    volumes:
      - pgdata3:/data/db
      - ./config/patroni3.yml:/etc/patroni.yml:ro
      - ./logs:/var/log/postgresql
    environment:
      PATRONI_CONFIG_PATH: /etc/patroni.yml
    deploy:
      resources:
        limits:
          memory: ${PG_MEM_LIMIT}
          cpus: '2.0'
        reservations:
          memory: 1G
          cpus: '0.5'
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -fsu patroni:${CHECK_PASSWORD} http://localhost:8008/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s

  # -------------------------------------------------------------------------
  # HAProxy – read/write & read‑only VIPs + stats
  # -------------------------------------------------------------------------
  haproxy:
    image: haproxy:2.9
    hostname: haproxy
    networks: [pgnet]
    depends_on:
      patroni1:
        condition: service_healthy
      patroni2:
        condition: service_healthy
      patroni3:
        condition: service_healthy
    ports:
      - "5432:5432"
      - "5433:5433"
      - "7001:7001"
    volumes:
      - ./config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    deploy:
      resources:
        limits:
          memory: ${HAPROXY_MEM_LIMIT}
          cpus: '0.5'
        reservations:
          memory: 64M
          cpus: '0.1'
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "haproxy", "-c", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
      interval: 30s
      timeout: 10s
      retries: 3

  # -------------------------------------------------------------------------
  # PostgreSQL metrics exporter (feeds the PostgreSQL Grafana dashboard)
  # -------------------------------------------------------------------------
  postgres-exporter:
    # v0.15 = last version with simple DATA_SOURCE_NAME env (v0.16+ needs
    # the new auth_modules config schema)
    image: quay.io/prometheuscommunity/postgres-exporter:v0.15.0
    hostname: postgres-exporter
    networks: [pgnet]
    depends_on:
      haproxy:
        condition: service_healthy
    environment:
      DATA_SOURCE_NAME: "postgresql://monitor:${CHECK_PASSWORD_ENC}@haproxy:5432/postgres?sslmode=disable"
    deploy:
      resources:
        limits:
          memory: 128M
          cpus: '0.2'
        reservations:
          memory: 64M
          cpus: '0.05'
    restart: unless-stopped

  # -------------------------------------------------------------------------
  # Monitoring with Prometheus + Grafana
  # -------------------------------------------------------------------------
  prometheus:
    image: prom/prometheus:v2.45.0
    hostname: prometheus
    networks: [pgnet]
    ports:
      - "9090:9090"
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--storage.tsdb.retention.time=200h'
      - '--web.enable-lifecycle'
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '0.5'
        reservations:
          memory: 256M
          cpus: '0.1'
    restart: unless-stopped

  grafana:
    image: grafana/grafana:12.4.11
    hostname: grafana
    networks: [pgnet]
    ports:
      - "3000:3000"
    environment:
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_SECURITY_ADMIN_USER: "admin"
      GF_SECURITY_ADMIN_PASSWORD: "${POSTGRES_PASSWORD}"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./config/grafana/dashboards:/etc/grafana/provisioning/dashboards
      - ./config/grafana/datasources:/etc/grafana/provisioning/datasources
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: '0.3'
        reservations:
          memory: 128M
          cpus: '0.1'
    restart: unless-stopped
EOF
envsubst < docker-compose.yml > docker-compose.yml.tmp && mv docker-compose.yml.tmp docker-compose.yml

### --------------------------------------------------------------------------
### 7. Monitoring Configuration
### --------------------------------------------------------------------------
mkdir -p config/grafana/{dashboards,datasources}

# Prometheus configuration
cat > config/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "postgresql_rules.yml"

scrape_configs:
  - job_name: 'patroni'
    static_configs:
      - targets: ['patroni1:8008', 'patroni2:8008', 'patroni3:8008']
    metrics_path: /metrics
    basic_auth:
      username: patroni
      password: ${CHECK_PASSWORD}
    scrape_interval: 10s

  - job_name: 'haproxy'
    static_configs:
      - targets: ['haproxy:8404']
    metrics_path: /metrics
    scrape_interval: 10s

  - job_name: 'etcd'
    static_configs:
      - targets: ['etcd1:2379', 'etcd2:2379', 'etcd3:2379']
    metrics_path: /metrics
    scrape_interval: 10s

  - job_name: 'postgresql-exporter'
    static_configs:
      - targets: ['postgres-exporter:9187']
    metrics_path: /metrics
    scrape_interval: 10s
EOF
envsubst < config/prometheus.yml > config/prometheus.yml.tmp && mv config/prometheus.yml.tmp config/prometheus.yml

# Grafana datasource
cat > config/grafana/datasources/prometheus.yml <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF

# Grafana dashboard provisioning
cat > config/grafana/dashboards/dashboard.yml <<'EOF'
apiVersion: 1

providers:
  - name: 'PostgreSQL'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

# --- Dashboards: community (pinned latest) + custom Patroni overview ---
# Uses postgres-exporter (9628) and HAProxy prometheus-exporter (12693)curl -fsSL -m 60 "https://grafana.com/api/dashboards/9628/revisions/latest/download" \
  -o config/grafana/dashboards/postgres.json \
  || echo "[WARN] could not fetch dashboard 9628 (PostgreSQL)"
curl -fsSL -m 60 "https://grafana.com/api/dashboards/12693/revisions/latest/download" \
  -o config/grafana/dashboards/haproxy.json \
  || echo "[WARN] could not fetch dashboard 12693 (HAProxy)"

cat > config/grafana/dashboards/patroni.json <<'EOF'
{
  "annotations": {"list": []},
  "editable": true,
  "refresh": "10s",
  "schemaVersion": 39,
  "tags": ["patroni", "postgres"],
  "templating": {"list": []},
  "time": {"from": "now-3h", "to": "now"},
  "timezone": "browser",
  "title": "Patroni Cluster Overview",
  "uid": "patroni-overview",
  "version": 1,
  "panels": [
    {
      "id": 1, "type": "stat", "title": "Postgres processes running",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A", "expr": "sum(patroni_postgres_running)", "legendFormat": "running"}],
      "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}
    },
    {
      "id": 2, "type": "stat", "title": "Leader",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A", "expr": "sum(patroni_master)", "legendFormat": "leader"}],
      "gridPos": {"h": 4, "w": 6, "x": 6, "y": 0},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}
    },
    {
      "id": 3, "type": "stat", "title": "Streaming replicas",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A", "expr": "sum(patroni_postgres_streaming)", "legendFormat": "streaming"}],
      "gridPos": {"h": 4, "w": 6, "x": 12, "y": 0},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}
    },
    {
      "id": 4, "type": "stat", "title": "DCS last seen (s ago)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [{"refId": "A", "expr": "time() - min(patroni_dcs_last_seen)", "legendFormat": "age"}],
      "gridPos": {"h": 4, "w": 6, "x": 18, "y": 0},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}
    },
    {
      "id": 5, "type": "timeseries", "title": "Replication lag (bytes)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [
        {"refId": "A", "expr": "patroni_xlog_location - patroni_xlog_replayed_location", "legendFormat": "{{instance}} replay lag"},
        {"refId": "B", "expr": "patroni_xlog_location - patroni_xlog_received_location", "legendFormat": "{{instance}} receive lag"}
      ],
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4},
      "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["lastNotNull"]}}
    },
    {
      "id": 6, "type": "timeseries", "title": "WAL position (bytes)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "targets": [
        {"refId": "A", "expr": "patroni_xlog_location", "legendFormat": "{{instance}}"}
      ],
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4},
      "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["lastNotNull"]}}
    }
  ]
}
EOF

### --------------------------------------------------------------------------
### 8. Backup Configuration
### --------------------------------------------------------------------------
cat > config/backup.sh <<'EOF'
#!/bin/bash
# Automated backup script for PostgreSQL cluster

# Resolve script location so the job works from cron and any cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$COMPOSE_DIR/backups"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=7

# Create backup directory
cd "$COMPOSE_DIR"
mkdir -p "$BACKUP_DIR"

# Perform logical backup using pg_dump
docker compose exec -T patroni1 pg_dumpall -U postgres > "$BACKUP_DIR/full_backup_$DATE.sql"

# Compress backup
gzip "$BACKUP_DIR/full_backup_$DATE.sql"

# Remove old backups
find "$BACKUP_DIR" -name "full_backup_*.sql.gz" -mtime +$RETENTION_DAYS -delete

echo "Backup completed: full_backup_$DATE.sql.gz"
EOF

chmod +x config/backup.sh

### --------------------------------------------------------------------------
### 9. Start the cluster
### --------------------------------------------------------------------------
echo "[INFO] Starting PostgreSQL HA cluster..."
docker compose pull --ignore-buildable
docker compose up -d --build

echo "[INFO] Waiting for Patroni primary to become available via HAProxy..."
PRIMARY_READY=0
for i in $(seq 1 60); do
  if docker compose exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" patroni1 \
       psql -h haproxy -U postgres -d postgres -c '\q' >/dev/null 2>&1; then
    PRIMARY_READY=1
    echo "[INFO] Primary is up (attempt $i)"
    break
  fi
  sleep 5
done
if [ "$PRIMARY_READY" != "1" ]; then
  echo "[ERROR] Primary did not become available in time. Last logs:"
  docker compose logs --tail=50 patroni1 patroni2 patroni3
  exit 1
fi

### --------------------------------------------------------------------------
### 10. Seed utility users and create monitoring user
### --------------------------------------------------------------------------
# Seed runs against the primary through HAProxy (port 5432) so it works
# regardless of which node currently holds the leader role.
docker compose exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" patroni1 psql -h haproxy -U postgres -d postgres <<EOSQL
DO
\$\$
BEGIN
  -- Create utility users
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'haproxy_check') THEN
     CREATE ROLE haproxy_check LOGIN;
  END IF;
  
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pooler') THEN
     CREATE ROLE pooler LOGIN PASSWORD '${POOL_PASSWORD}';
  END IF;
  
  -- Create monitoring user
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'monitor') THEN
     CREATE ROLE monitor LOGIN PASSWORD '${CHECK_PASSWORD}';
     GRANT pg_monitor TO monitor;
  END IF;
  
  -- Create application user
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
     CREATE ROLE app_user LOGIN PASSWORD '${POOL_PASSWORD}';
  END IF;
END
\$\$;

-- Create database outside of function (idempotent via \gexec)
SELECT 'CREATE DATABASE app_db OWNER app_user;'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'app_db')\gexec
SELECT 'GRANT ALL PRIVILEGES ON DATABASE app_db TO app_user;'
WHERE EXISTS (SELECT FROM pg_database WHERE datname = 'app_db')\gexec
EOSQL

### --------------------------------------------------------------------------
### 11. Setup automated backups
### --------------------------------------------------------------------------
# Add to crontab for daily backups at 2 AM
(crontab -l 2>/dev/null | grep -v 'config/backup.sh'; echo "0 2 * * * $(pwd)/config/backup.sh") | crontab -

### --------------------------------------------------------------------------
### 12. Performance tuning script
### --------------------------------------------------------------------------
cat > config/tune_performance.sh <<'EOF'
#!/bin/bash
# Performance tuning script for PostgreSQL

echo "Tuning PostgreSQL performance..."

# Detect OS and apply appropriate tuning
if [[ "$OSTYPE" == "darwin"* ]]; then
  echo "[INFO] macOS detected - kernel tuning not available"
  echo "For macOS, consider adjusting Docker Desktop memory allocation"
  echo "Recommended: 4GB+ RAM for Docker Desktop"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
  # Linux kernel tuning
  echo 'vm.swappiness=1' >> /etc/sysctl.conf
  echo 'vm.dirty_ratio=15' >> /etc/sysctl.conf
  echo 'vm.dirty_background_ratio=5' >> /etc/sysctl.conf
  
  # Apply changes
  sysctl -p
  echo "[INFO] Linux kernel parameters applied"
else
  echo "[INFO] Unknown OS - skipping kernel tuning"
fi

echo "Performance tuning completed."
EOF

chmod +x config/tune_performance.sh

### --------------------------------------------------------------------------
### 13. Health check script
### --------------------------------------------------------------------------
cat > config/health_check.sh <<'EOF'
#!/bin/bash
# Health check script for PostgreSQL cluster
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1

echo "Checking cluster health..."

# Check Patroni status
docker compose exec -T patroni1 patronictl -c /etc/patroni.yml list

# Check HAProxy stats
curl -s http://localhost:7001/ | grep -q "postgres" && echo "HAProxy: OK" || echo "HAProxy: FAILED"

echo "Health check completed."
EOF

chmod +x config/health_check.sh

### --------------------------------------------------------------------------
### 14. Final output with production information
### --------------------------------------------------------------------------
cat <<EOM
------------------------------------------------------------------------------
🎉  Production PostgreSQL HA stack is up and running!

📊 **Connection Endpoints:**
•  Read/Write endpoint :  host:<server_ip>  port:5432  (via HAProxy - RECOMMENDED)
•  Read‑only endpoint  :  host:<server_ip>  port:5433

🔐 **Default credentials:**
   superuser : postgres / ${POSTGRES_PASSWORD}
   pooler    : pooler   / ${POOL_PASSWORD}
   app_user  : app_user / ${POOL_PASSWORD}

📈 **Monitoring:**
•  HAProxy Stats: http://<server_ip>:7001 (admin:${CHECK_PASSWORD})
•  Grafana: http://<server_ip>:3000 (admin:${POSTGRES_PASSWORD}) – dashboards auto-provisioned: Patroni Cluster Overview, PostgreSQL Database, HAProxy
•  Prometheus: http://<server_ip>:9090

⚡ **Performance Optimizations Applied:**
•  Resource limits configured for minimal usage
•  Optimized PostgreSQL parameters for 1M users
•  Load balancing with HAProxy
•  Automated backups configured
•  Monitoring with Prometheus + Grafana

🔧 **Management Commands:**
•  Check cluster status: docker compose exec patroni1 patronictl -c /etc/patroni.yml list
•  Health check: ./config/health_check.sh
•  Manual backup: ./config/backup.sh
•  Performance tuning: ./config/tune_performance.sh

📋 **Production Recommendations:**
1. Use the HAProxy endpoint (port 5432) for applications
2. Monitor via Grafana dashboard
3. Set up alerting in Grafana
4. Configure log rotation
5. Consider using pgBackRest for advanced backups
6. Implement connection pooling in your application
7. Monitor resource usage and adjust limits as needed
8. For macOS: Ensure Docker Desktop has sufficient memory allocation (4GB+ recommended)

🚀 **Ready for 1M users with minimal resource usage!**
------------------------------------------------------------------------------
EOM
