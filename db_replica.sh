#!/bin/bash

echo "⏳ Waiting for db-master to start..."
until docker exec db-master mysqladmin ping -h "localhost" -u root -ppassword --silent; do
    sleep 2
done

echo "🏗️ Ensuring Database Schema on Master..."
docker exec db-master mysql -u root -ppassword -e "
CREATE USER IF NOT EXISTS 'replicator'@'%' IDENTIFIED WITH mysql_native_password BY 'password';
ALTER USER 'replicator'@'%' IDENTIFIED WITH mysql_native_password BY 'password';

GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%';

SET GLOBAL max_connections = 2000;
SET GLOBAL innodb_flush_log_at_trx_commit = 2;
SET GLOBAL sync_binlog = 0;
SET GLOBAL innodb_buffer_pool_size = 536870912;

CREATE DATABASE IF NOT EXISTS app_db;
GRANT ALL PRIVILEGES ON app_db.* TO 'replicator'@'%';
USE app_db;

CREATE TABLE IF NOT EXISTS entries (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100),
    email VARCHAR(100),
    message TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

FLUSH PRIVILEGES;"

echo "📝 Fetching Master Binary Log Coordinates..."
MASTER_STATUS=$(docker exec db-master mysql -u root -ppassword -e "SHOW MASTER STATUS\G")
CURRENT_LOG=$(echo "$MASTER_STATUS" | grep File | awk '{print $2}')
CURRENT_POS=$(echo "$MASTER_STATUS" | grep Position | awk '{print $2}')

if [ -z "$CURRENT_LOG" ]; then
    echo "❌ Error: Master log-bin not found. Ensure master.cnf has 'log-bin=mysql-bin'."
    exit 1
fi

SLAVE_CONTAINERS=$(docker ps --filter "name=db-slave" --format "{{.Names}}")

for SLAVE_NAME in $SLAVE_CONTAINERS; do
    echo "🔍 Checking status of $SLAVE_NAME..."

    SLAVE_HEALTH=$(docker exec "$SLAVE_NAME" mysql -u root -ppassword -e "SHOW SLAVE STATUS\G" | grep "Slave_IO_Running" | awk '{print $2}')

    if [ "$SLAVE_HEALTH" == "Yes" ]; then
        echo "✅ $SLAVE_NAME is already synchronized. Skipping configuration."
    else
        echo "🔗 Establishing Handshake for $SLAVE_NAME..."
        docker exec "$SLAVE_NAME" mysql -u root -ppassword -e "
        STOP SLAVE;
        RESET SLAVE;
        CREATE USER IF NOT EXISTS 'replicator'@'%'; 
        ALTER USER 'replicator'@'%' IDENTIFIED BY 'password';
        FLUSH PRIVILEGES;
        GRANT ALL PRIVILEGES ON app_db.* TO 'replicator'@'%';
        CHANGE MASTER TO
            MASTER_HOST='db-master',
            MASTER_USER='replicator',
            MASTER_PASSWORD='password',
            MASTER_LOG_FILE='$CURRENT_LOG',
            MASTER_LOG_POS=$CURRENT_POS;
        START SLAVE;
        "
        echo "🚀 $SLAVE_NAME is now tracking Master at $CURRENT_POS."
    fi
done

echo "✨ Cluster Synchronization Complete!"
