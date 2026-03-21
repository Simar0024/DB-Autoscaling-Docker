const express = require('express');
const mysql = require('mysql2/promise');
const os = require('os');
const app = express();

app.use(express.json());

// Unified Configuration
const poolConfig = {
    host: process.env.DB_HOST || 'db-slave',
    user: 'replicator',
    password: 'password',
    database: 'app_db',
    waitForConnections: true,
    connectionLimit: 50,
    queueLimit: 0,
    connectTimeout: 10000
};

// Create Pools
const slavePool = mysql.createPool(poolConfig);
const masterPool = mysql.createPool({ ...poolConfig, host: 'db-master' });

// --- DATA READ (SLAVE) ---
app.get('/api/data', async (req, res) => {
    try {
        const [rows] = await slavePool.query(`
            SELECT id, name, email, message, created_at 
            FROM entries 
            FORCE INDEX (PRIMARY)
            ORDER BY id DESC 
            LIMIT 20
        `);

        res.set('Cache-Control', 'no-store');
        res.json({ 
            source: 'Slave Cluster', 
            served_by: os.hostname(), 
            data: rows,
            timestamp: Date.now() 
        });
    } catch (err) {
        console.error("Read Error:", err.message);
        res.status(500).json({ error: "High Latency / Sync Error" });
    }
});

// --- HEALTH CHECK (SLAVE) ---
app.get('/api/health', async (req, res) => {
    try {
        // FIXED: Changed 'pool' to 'slavePool'
        const connection = await slavePool.getConnection();
        await connection.query('SELECT 1');
        connection.release();

        const metrics = {
            cpu: (os.loadavg()[0] * 10).toFixed(2) + "%",
            memory: ((1 - os.freemem() / os.totalmem()) * 100).toFixed(2) + "%"
        };

        res.status(200).json({ 
            status: 'healthy', 
            served_by: os.hostname(),
            metrics 
        });
    } catch (err) {
        console.error("Health Check Failure:", err.message);
        res.status(503).json({ status: 'unhealthy', error: err.message });
    }
});

// --- DATA WRITE (MASTER) ---
app.post('/api/data', async (req, res) => {
    try {
        const { name, email, message } = req.body;
        await masterPool.query(
            'INSERT INTO entries (name, email, message) VALUES (?, ?, ?)',
            [name || 'Locust User', email || 'locust@test.com', message || 'Load Test']
        );
        res.json({ status: 'Success', db_node: 'master' });
    } catch (err) {
        console.error("Write Error:", err.message);
        res.status(500).json({ error: "Master Offline" });
    }
});

app.listen(3000, '0.0.0.0', () => {
    console.log(`🚀 Backend ${os.hostname()} listening on port 3000`);
});
