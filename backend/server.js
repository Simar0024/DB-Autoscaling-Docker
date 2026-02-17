const express = require('express');
const mysql = require('mysql2/promise');
const os = require('os');
const app = express();

app.use(express.json());

const poolConfig = {
    host: 'db-slave',
    user: 'root',
    password: 'password',
    database: 'app_db',
    connectionLimit: 50,
    queueLimit: 0,
    connectTimeout: 10000
};

const slavePool = mysql.createPool(poolConfig);
const masterPool = mysql.createPool({ ...poolConfig, host: 'db-master' });

app.get('/api/data', async (req, res) => {
    try {
        const [rows] = await slavePool.query(`
            SELECT id, name, email, message, created_at
            FROM entries
            ORDER BY id DESC LIMIT 50
        `);

        res.json({
            source: 'Slave Cluster',
            served_by: os.hostname(),
            data: rows
        });
    } catch (err) {
        console.error("DB Busy:", err.message);
        res.status(503).json({ error: "Database Busy", data: [] });
    }
});

app.post('/api/data', async (req, res) => {
    try {
        const { name, email, message } = req.body;
        await masterPool.query(
            'INSERT INTO entries (name, email, message) VALUES (?, ?, ?)',
            [name || 'Locust User', email || 'locust@test.com', message || 'Load Test']
        );
        res.json({ status: 'Success', db_node: 'master' });
    } catch (err) {
        res.status(500).json({ error: "Master Offline" });
    }
});

app.listen(3000, '0.0.0.0');
