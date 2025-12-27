#!/bin/bash
# Starts the Zephyria node in the background, keeping stdin open to prevent exit.
# Usage: ./scripts/start.sh [-mine]

# Cleanup ports
echo "🧹 Cleaning up port 8545..."
lsof -ti:8545 | xargs kill -9 2>/dev/null || true
sleep 1

make zephyria

echo "Starting Zephyria Node..."
if [ "$1" == "-mine" ]; then
    echo "Mining enabled."
    tail -f /dev/null | ./zephyria -mine > node.log 2>&1 &
else
    tail -f /dev/null | ./zephyria > node.log 2>&1 &
fi
echo "Node started. Logs in node.log"
