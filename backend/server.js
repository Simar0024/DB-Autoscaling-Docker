const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');
const { HttpInstrumentation } = require('@opentelemetry/instrumentation-http');
const { MySQL2Instrumentation } = require('@opentelemetry/instrumentation-mysql2');

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter({
    url: 'grpc://jaeger:4317', 
  }),
  instrumentations: [new HttpInstrumentation(), new MySQL2Instrumentation()],
  serviceName: 'backend-service',
});

sdk.start();

const express = require('express');
const winston = require('winston');
const LokiTransport = require('winston-loki');

// LOGGING: Push logs to Loki instead of just console
const logger = winston.createLogger({
  transports: [
    new LokiTransport({
      host: 'http://loki:3100',
      labels: { app: 'backend' },
      json: true
    }),
    new winston.transports.Console()
  ]
});

const mysql = require('mysql2/promise');
const os = require('os');
const client = require('prom-client');

const app = express();
app.use(express.json());

const register = new client.Registry();
const cpuGauge = new client.Gauge({
    name: 'backend_cpu_usage',
    help: 'Current CPU usage percentage',
    registers: [register],
});

const getCpuUsage = () => {
    const load = os.loadavg()[0]; 
    const cores = os.cpus().length;
    const usage = (load / cores) * 100;
    return usage.toFixed(2);
};

const poolConfig = {
    user: 'replicator',
    password: 'password',
    database: 'app_db',
    waitForConnections: true,
    connectionLimit: 50,
    queueLimit: 0,
    connectTimeout: 10000
};

const masterPool = mysql.createPool({ ...poolConfig, host: process.env.DB_MASTER || 'db-master' });
const slavePool = mysql.createPool({ ...poolConfig, host: process.env.DB_SLAVE || 'db-slave' });

// FIXED: Added metrics to the data response so the UI can update badges
app.get('/api/data', async (req, res) => {
    logger.info('Fetching data from slave pool');
    try {
        const [rows] = await slavePool.query(`
            SELECT id, name, email, message, created_at 
            FROM entries 
            ORDER BY id DESC 
            LIMIT 20
        `);
        
        const currentCpu = getCpuUsage();
        const currentMem = ((1 - os.freemem() / os.totalmem()) * 100).toFixed(2) + "%";

        res.set('Cache-Control', 'no-store');
        res.json({ 
            source: 'Slave Cluster', 
            served_by: os.hostname(), 
            data: rows,
            metrics: {
                cpu: currentCpu + "%",
                memory: currentMem
            }
        });
    } catch (err) {
        res.status(500).json({ error: "Read Latency/Sync Error", detail: err.message });
    }
});

app.post('/api/data', async (req, res) => {
    logger.info('Inserting data into master pool');
    try {
        const { name, email, message } = req.body;
        await masterPool.query(
            'INSERT INTO entries (name, email, message) VALUES (?, ?, ?)',
            [name || 'Locust User', email || 'locust@test.com', message || 'Load Test']
        );
        res.json({ status: 'Success', db_node: 'master' });
    } catch (err) {
        res.status(500).json({ error: "Master Offline", detail: err.message });
    }
});

app.get('/api/health', async (req, res) => {
    try {
        const connection = await slavePool.getConnection();
        await connection.query('SELECT 1');
        connection.release();

        const currentCpu = getCpuUsage();
        res.status(200).json({ 
            status: 'healthy', 
            served_by: os.hostname(),
            cpu: currentCpu,
            memory: ((1 - os.freemem() / os.totalmem()) * 100).toFixed(2) + "%"
        });
    } catch (err) {
        res.status(503).json({ status: 'unhealthy', error: err.message });
    }
});

app.get('/metrics', async (req, res) => {
    try {
        const currentCpu = getCpuUsage();
        cpuGauge.set(parseFloat(currentCpu)); 
        res.set('Content-Type', register.contentType);
        res.end(await register.metrics());
    } catch (err) {
        res.status(500).end(err);
    }
});

const PORT = 3000;
app.listen(PORT, '0.0.0.0', () => {
    console.log(`🚀 Backend ${os.hostname()} online on port ${PORT}`);
});