#!/bin/bash

# --- CONFIGURATION ---
THRESHOLD_UP=40
THRESHOLD_DOWN=15
MIN_SLAVES=2
MAX_SLAVES=8
CHECK_INTERVAL=5

async_configure_slave() {
    local i=$1
    local SLAVE_NAME="new-db-docker-db-slave-$i"

    echo "⏳ Waiting for MySQL to finish initializing $SLAVE_NAME..."
    
    # Increase the sleep and check for actual 'ready' status
    MAX_RETRIES=30
    RETRIES=0
    until docker exec $SLAVE_NAME mysqladmin ping -h localhost -uroot --silent || [ $RETRIES -eq $MAX_RETRIES ]; do
        echo "🔄 DB is still initializing (Attempt $((RETRIES+1))/$MAX_RETRIES)..."
        sleep 10
        ((RETRIES++))
    done

    if [ $RETRIES -eq $MAX_RETRIES ]; then
        echo "❌ DB $SLAVE_NAME failed to start in time. Scaling aborted."
        exit 1
    fi

    echo "✅ DB is finally ready! Injecting schema..."
    
    # 1. Manually create the DB first to ensure the dump has a target
    docker exec $SLAVE_NAME mysql -uroot -e "CREATE DATABASE IF NOT EXISTS app_db;"

    # 2. Inject schema from Master
    docker exec -i new-db-docker-db-master-1 mysqldump -uroot app_db --no-data | docker exec -i $SLAVE_NAME mysql -uroot app_db

    # 3. Setup User (MySQL 8.0 Friendly)
    docker exec $SLAVE_NAME mysql -uroot -e "
        CREATE USER IF NOT EXISTS 'replicator'@'%';
        ALTER USER 'replicator'@'%' IDENTIFIED WITH mysql_native_password BY 'password';
        GRANT ALL PRIVILEGES ON app_db.* TO 'replicator'@'%';
        FLUSH PRIVILEGES;
        
        CHANGE MASTER TO 
            MASTER_HOST='db-master', 
            MASTER_USER='replicator', 
            MASTER_PASSWORD='password', 
            GET_MASTER_PUBLIC_KEY=1;
        START SLAVE;
    "
}

while true; do
    # 1. Get ONLY healthy backends to query their API
    HEALTHY_BACKENDS=$(docker ps --filter "name=backend" --filter "status=running" --filter "health=healthy" -q)
    
    TOTAL_CPU=0
    COUNT=0

    if [ -z "$HEALTHY_BACKENDS" ]; then
        echo "⚠️  No healthy backends found. Scaling logic paused..."
        AVG_CPU=0
    else
        for cid in $HEALTHY_BACKENDS; do
            # 2. Query the Health API instead of Docker Stats
            # Extracting the "cpu" value from: {"status":"healthy","metrics":{"cpu":"12.50%","memory":"45%"}}
            CPU_VAL=$(docker exec $cid curl -s http://localhost:3000/api/health | grep -oP '"cpu":"\K[0-9.]+')
            
            if [[ $CPU_VAL =~ ^[0-9.]+$ ]]; then
                TOTAL_CPU=$(echo "$TOTAL_CPU + $CPU_VAL" | bc)
                COUNT=$((COUNT + 1))
            fi
        done

        if [ $COUNT -gt 0 ]; then
            AVG_CPU=$(echo "scale=0; $TOTAL_CPU / $COUNT" | bc)
        else
            AVG_CPU=0
        fi
    fi

    CURRENT_SLAVES=$(docker ps --filter "name=db-slave" --filter "status=running" -q | wc -l)
    echo "📊 [API METRICS] Avg App Load: ${AVG_CPU}% | Active Nodes: $CURRENT_SLAVES"

    # --- SCALING LOGIC ---
    if [ "$(echo "$AVG_CPU > $THRESHOLD_UP" | bc)" -eq 1 ] && [ "$CURRENT_SLAVES" -lt "$MAX_SLAVES" ]; then
        NEW_COUNT=$((CURRENT_SLAVES + 2))
        echo "🔥 API Load High! Scaling to $NEW_COUNT..."
        docker compose up -d --scale db-slave=$NEW_COUNT --scale backend=$NEW_COUNT
        async_configure_slave $NEW_COUNT & 
    elif [ "$(echo "$AVG_CPU < $THRESHOLD_DOWN" | bc)" -eq 1 ] && [ "$CURRENT_SLAVES" -gt "$MIN_SLAVES" ]; then
        NEW_COUNT=$((CURRENT_SLAVES - 1))
        echo "❄️ API Load Low. Scaling down to $NEW_COUNT..."
        docker compose up -d --scale db-slave=$NEW_COUNT --scale backend=$NEW_COUNT
    fi

    sleep $CHECK_INTERVAL
done
