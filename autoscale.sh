#!/bin/bash

# --- CONFIGURATION ---
TARGET_CPU=40
MIN_NODES=2
MAX_NODES=8
PROJECT_NAME="db-autoscaling-docker"
COOLDOWN=30 # Seconds to wait after scaling

echo "🚀 Starting Robust Autoscaler..."

while true; do
    # 1. PRE-CHECK: Wait until at least MIN_NODES are healthy
    HEALTHY_NAMES=$(docker ps --filter "name=backend" --filter "status=running" --format "{{.Names}} {{.Status}}" | grep "(healthy)" | awk '{print $1}')
    COUNT=$(echo "$HEALTHY_NAMES" | grep -v '^$' | wc -l)

    if [ "$COUNT" -lt "$MIN_NODES" ]; then
        echo "⏳ System Initialization: Only $COUNT/$MIN_NODES nodes healthy. Waiting..."
        sleep 5
        continue
    fi

    # 2. METRIC COLLECTION
    TOTAL_CPU=0
    ACTUAL_MEASURED=0

    for NAME in $HEALTHY_NAMES; do
        # Extract numerical CPU value from API
        STATS=$(docker exec "$NAME" curl -s http://localhost:3000/api/health | grep -oP '"cpu":"\K[0-9.]+')
        
        if [[ ! -z "$STATS" ]]; then
            # Ignore boot spikes > 150% to prevent "panic scaling"
            if (( $(echo "$STATS < 150" | bc -l) )); then
                TOTAL_CPU=$(echo "$TOTAL_CPU + $STATS" | bc)
                ACTUAL_MEASURED=$((ACTUAL_MEASURED + 1))
                echo "📍 Node $NAME: $STATS%"
            fi
        fi
    done

    # 3. AVERAGE CALCULATION
    if [ "$ACTUAL_MEASURED" -gt 0 ]; then
        AVG_LOAD=$(echo "scale=2; $TOTAL_CPU / $ACTUAL_MEASURED" | bc)
        echo "📊 [CLUSTER STATUS] Avg Load: $AVG_LOAD% | Active Healthy Nodes: $ACTUAL_MEASURED"
    else
        echo "⚠️ Failed to scrape metrics from healthy nodes. Retrying..."
        sleep 5
        continue
    fi

    # 4. DECISION MATRIX
    # Check if we need to scale UP
    if (( $(echo "$AVG_LOAD > $TARGET_CPU" | bc -l) )); then
        if [ "$ACTUAL_MEASURED" -lt "$MAX_NODES" ]; then
            NEW_COUNT=$((ACTUAL_MEASURED + 2))
            [ $NEW_COUNT -gt $MAX_NODES ] && NEW_COUNT=$MAX_NODES
            
            echo "🔥 LOAD HIGH ($AVG_LOAD%). Scaling UP to $NEW_COUNT..."
            docker compose up -d --scale backend=$NEW_COUNT --scale db-slave=$NEW_COUNT
            
            echo "🛌 Entering Cooldown for $COOLDOWN seconds..."
            sleep $COOLDOWN
        else
            echo "ℹ️ Max nodes ($MAX_NODES) reached. Cannot scale up further."
        fi

    # Check if we can scale DOWN
    elif (( $(echo "$AVG_LOAD < 20" | bc -l) )); then
        if [ "$ACTUAL_MEASURED" -gt "$MIN_NODES" ]; then
            NEW_COUNT=$((ACTUAL_MEASURED - 1))
            echo "❄️ LOAD LOW ($AVG_LOAD%). Scaling DOWN to $NEW_COUNT..."
            docker compose up -d --scale backend=$NEW_COUNT --scale db-slave=$NEW_COUNT
            sleep 20
        fi
    fi

    sleep 5
done