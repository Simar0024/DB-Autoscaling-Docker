#!/bin/bash

THRESHOLD_UP=40
THRESHOLD_DOWN=15
MIN_SLAVES=2
MAX_SLAVES=8

configure_slave() {
    local i=$1
    local SLAVE_NAME="new-db-docker-db-slave-$i"

    echo "⚙️  Configuring $SLAVE_NAME..."
    until docker exec $SLAVE_NAME mysqladmin ping -h localhost -uroot -ppassword --silent; do
        sleep 2
    done

    UNIQUE_ID=$((100 + i))
    docker exec $SLAVE_NAME mysql -uroot -ppassword -e "
        SET GLOBAL server_id = $UNIQUE_ID;
        STOP SLAVE;
        CHANGE MASTER TO
            MASTER_HOST='db-master',
            MASTER_USER='replicator',
            MASTER_PASSWORD='password',
            GET_MASTER_PUBLIC_KEY=1;
        START SLAVE;
    "
    echo "✅ $SLAVE_NAME is ONLINE and SYNCED."
}

echo "🤖 Autoscaler Initialized. Monitoring Cluster CPU..."

while true; do
    CPU_RAW=$(docker stats --no-stream --format "{{.CPUPerc}}" $(docker ps --filter "name=backend" -q))
    TOTAL_CPU=0
    COUNT=0
    for val in $CPU_RAW; do
        num=$(echo $val | sed 's/%//')
        TOTAL_CPU=$(echo "$TOTAL_CPU + $num" | bc)
        COUNT=$((COUNT + 1))
    done

    if [ $COUNT -eq 0 ]; then AVG_CPU=0; else
        AVG_CPU=$(echo "$TOTAL_CPU / $COUNT" | bc)
    fi

    CURRENT_SLAVES=$(docker ps --filter "name=db-slave" -q | wc -l)

    echo "📊 Avg CPU: $AVG_CPU% | Current Slaves: $CURRENT_SLAVES "

    if (( $(echo "$AVG_CPU > $THRESHOLD_UP" | bc -l) )) && [ $CURRENT_SLAVES -lt $MAX_SLAVES ]; then
        NEW_COUNT=$((CURRENT_SLAVES + 1))
        echo "🔥 CPU HIGH ($AVG_CPU%)! Scaling Out to $NEW_COUNT..."
        docker compose up -d --scale db-slave=$NEW_COUNT --scale backend=$NEW_COUNT
        configure_slave $NEW_COUNT
    elif (( $(echo "$AVG_CPU < $THRESHOLD_DOWN" | bc -l) )) && [ $CURRENT_SLAVES -gt $MIN_SLAVES ]; then
        NEW_COUNT=$((CURRENT_SLAVES - 1))
        echo "❄️ CPU LOW ($AVG_CPU%)! Scaling In to $NEW_COUNT..."
        docker compose up -d --scale db-slave=$NEW_COUNT --scale backend=$NEW_COUNT
    fi

    sleep 5
done
