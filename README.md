# DB_Autoscaling_Docker

## 🚀 Project Overview

DB_Autoscaling_Docker demonstrates a full-stack Docker-based autoscaling prototype with MySQL master/slave replication, backend API clustering, a reverse proxy front-end, monitoring tools, and load generation.

Key components:

- `nginx` for static UI + reverse proxy to backend cluster
- `backend` (Node.js/Express) with read-from-slave and write-to-master split
- `db-master` MySQL primary
- `db-slave` MySQL replicas
- `prometheus` + `nginx-exporter` for metrics
- `grafana` dashboard for visualization
- `locustfile.py` load testing scenario
- `autoscale.sh` runtime scaling controller
- `db_replica.sh` replication setup

---

## 🧩 Architecture

- Nginx exposes one endpoint (`/api/*`).
- Backend replicas (Docker compose scaled) share HTTP load and access DB:
  - GET `/api/data` -> slave (reads)
  - POST `/api/data` -> master (writes)
- Master enforces DB schema and writes updates to binlog
- Slaves connect to master binlog and replicate writes using `replicator` user
- Health check endpoint `/api/health` returns CPU/memory metrics for autoscaler
- Prometheus scrapes Nginx exporter for request counters
- Grafana uses Prometheus datasource for real-time dashboarding

---

## 📦 Requirements

- Docker Engine (v20+)
- Docker Compose (v2+) or `docker compose`
- Node.js (for local backend dev only, optional)
- Locust (for load testing, optional)

---

## ⚡ Quick Start (All-in-One)

1. From repo root:

    ```bash
    docker compose up -d --build
    ```

2. Start replication bootstrap (wait for DB master to be healthy):

    ```bash
    ./db_replica.sh
    ```

3. Open services:
   - UI/Nginx: `http://localhost`
   - Prometheus: `http://localhost:9090`
   - Grafana: `http://localhost:3001` (user: `admin` / password: `admin`)

4. Optional load test from this host:

    ```bash
    locust -f locustfile.py --host=http://localhost
    ```

5. Optional autoscaling controller:

    ```bash
    chmod +x autoscale.sh
    ./autoscale.sh
    ```

---

## 🔧 Component Configuration

### Docker Compose

- `backend` depends on `db-master` being healthy and uses env vars:
  - `DB_MASTER=db-master`
  - `DB_SLAVE=db-slave`
- default backend pool points to `db-slave` for reads
- master pool is explicitly host `db-master` for writes

### MySQL Master (`mysql-master/master.cnf`)

- includes `log-bin=mysql-bin`, `server-id=1`, `binlog-format=row`

### MySQL Slave (`mysql-slave/slave.cnf`)

- includes `server-id=2`, `read_only=ON`, `relay_log` settings

### Analytics

- `prometheus/prometheus.yml` scrapes `nginx-exporter:9113`

---

## 🧪 API Endpoints

- `GET /api/data`
  - returns recent `entries` (slave read path)
  - JSON includes `source`, `served_by`, `timestamp`
- `POST /api/data`
  - inserts row into `entries` on master
  - request body keys: `name`, `email`, `message`
- `GET /api/health`
  - returns backend health, CPU and memory metrics

---

## 📝 Frontend Behavior

`frontend/index.html` is a static UI that:

- submits write payloads to `/api/data`
- polls `/api/data` every 1.2s
- renders table and charts for cluster nodes, latency, and traffic state
- dynamically highlights node metrics

---

## 🛠️ Autoscaling Script (`autoscale.sh`)

- Monitors backend API CPU from `/api/health` per container
- uses thresholds:
  - scale up if avg CPU > 40%
  - scale down if avg CPU < 15%
- maintains `MIN_SLAVES=2`, `MAX_SLAVES=8`
- scales with `docker compose up -d --scale db-slave=... --scale backend=...`
- configures new slaves asynchronously (`async_configure_slave`)

> note: this script uses container names from compose v2 (`db-autoscaling-docker-db-master-1`) and assumes consistent naming

---

## 📈 Replication Setup (`db_replica.sh`)

- waits for master `mysqladmin ping`
- creates `replicator` user with `mysql_native_password`
- creates `app_db.entries` table
- queries `SHOW MASTER STATUS`
- for each slave container, runs `CHANGE MASTER TO ...`, `START SLAVE`
- checks `Slave_IO_Running` and skips if already synced

---

## ✅ Validation

1. Ensure all containers are running:

   ```bash
   docker compose ps
   ```

2. Check backend logs for connected master/slave queries:

   ```bash
   docker logs -f backend
   ```

3. Inspect replication status:

   ```bash
   docker exec db-slave mysql -uroot -ppassword -e "SHOW SLAVE STATUS\G"
   ```

4. Hit API manually:

   ```bash
   curl http://localhost/api/data
   curl -X POST http://localhost/api/data -H 'Content-Type: application/json' -d '{"name":"x","email":"x@x.com","message":"hi"}'
   ```

---

## 🐞 Troubleshooting

- permission issues on scripts: `chmod +x autoscale.sh db_replica.sh`
- `docker compose up` fails due MySQL not ready: run `docker compose down && docker compose up -d` and rerun `./db_replica.sh`
- slaves stuck with `Slave_IO_Running: No` / `Slave_SQL_Running: No`:
  - verify `db-master` coordinates in `SHOW MASTER STATUS` and `CHANGE MASTER TO`
  - inspect `docker exec db-slave mysql -e 'SHOW SLAVE STATUS\G'`
- backend connect timeout: ensure the `replicator` user exists and password matches

---

## 🧾 Development Notes

- Backend is Node.js only (no auto npm script in compose): you can also run directly with:

  ```bash
  cd backend
  npm install
  node server.js
  ```

- To add more slaves in one shot:

  ```bash
  docker compose up -d --scale db-slave=4 --scale backend=4
  ./db_replica.sh
  ```

- For production, secure credentials and remove root tags from API.

---

## 🗂️ Directory Structure

- `backend/` - Express API container
- `frontend/` - UI static files
- `nginx/` - Nginx config and reverse proxy
- `mysql-master/`, `mysql-slave/` - MySQL configs
- `prometheus/` - monitoring config
- `locustfile.py` - load test scenario
- `autoscale.sh` - autoscaling daemon logic
- `db_replica.sh` - replication init script

---

## 📌 Credits

- Built for DB autoscaling demo with Docker Compose, MySQL replication, Prometheus, and Grafana.
- Author: Simarjit Singh

---
