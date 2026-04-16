#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="$REPO_ROOT/zig-out/bin/Pencil2D Animation.app/Contents/MacOS/pencil2d"
LOG="/tmp/pencil2d_debug.log"
PORT=9876
CYCLES=${1:-3}
CONCURRENCY=${2:-10}
DURATION=${3:-3} # seconds each worker runs
CURL_TIMEOUT="--connect-timeout 2 --max-time 5"

function mcp_post() {
  curl -sS $CURL_TIMEOUT -X POST -H 'Content-Type: application/json' -d "$1" http://127.0.0.1:$PORT/mcp
}

function wait_for_init() {
  for i in $(seq 1 30); do
    resp=$(mcp_post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":null}' 2>/dev/null || true)
    if [ -n "$resp" ]; then
      echo "  initialize OK"
      return 0
    fi
    sleep 1
  done
  return 1
}

PASS=0
FAIL=0

for cycle in $(seq 1 $CYCLES); do
  echo "=== Cycle $cycle/$CYCLES ==="
  rm -f "$LOG"
  MCP_DEV_TOOLS=1 "$APP_BIN" --mcp $PORT > "$LOG" 2>&1 &
  APP_PID=$!
  echo "  app pid=$APP_PID"
  if ! wait_for_init; then
    echo "  FAIL: server did not initialize"
    tail -n 30 "$LOG"
    kill $APP_PID 2>/dev/null || true
    FAIL=$((FAIL + 1))
    continue
  fi

  echo "  spawning $CONCURRENCY workers for ${DURATION}s"
  WORKER_PIDS=()
  for i in $(seq 1 $CONCURRENCY); do
    (
      end=$((SECONDS + DURATION))
      while [ $SECONDS -lt $end ]; do
        mcp_post '{"jsonrpc":"2.0","id":100,"method":"tools/call","params":{"name":"project_info","arguments":null}}' >/dev/null 2>&1 || true
        mcp_post '{"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"name":"draw_rect","arguments":{"layer":1,"x":10,"y":10,"w":10,"h":10}}}' >/dev/null 2>&1 || true
      done
    ) &
    WORKER_PIDS+=($!)
  done

  # let workers run, then trigger shutdown mid-flight
  sleep $((DURATION / 2 > 0 ? DURATION / 2 : 1))
  echo "  trigger server_shutdown"
  mcp_post '{"jsonrpc":"2.0","id":200,"method":"tools/call","params":{"name":"server_shutdown","arguments":null}}' 2>/dev/null || true

  # wait for workers (they'll time out via curl --max-time)
  for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # verify server is actually stopped
  if mcp_post '{"jsonrpc":"2.0","id":999,"method":"initialize","params":null}' >/dev/null 2>&1; then
    echo "  WARN: server still responding after shutdown"
  else
    echo "  server stopped OK"
  fi

  # kill the Qt app
  if ps -p $APP_PID >/dev/null 2>&1; then
    kill $APP_PID 2>/dev/null || true
    # wait briefly for clean exit
    for i in $(seq 1 5); do
      ps -p $APP_PID >/dev/null 2>&1 || break
      sleep 1
    done
    # force kill if still alive
    if ps -p $APP_PID >/dev/null 2>&1; then
      echo "  WARN: force killing app"
      kill -9 $APP_PID 2>/dev/null || true
    fi
  fi

  # check for crashes in log
  if grep -qiE 'segfault|panic|abort|SIGSEGV|SIGABRT|unreachable' "$LOG" 2>/dev/null; then
    echo "  FAIL: crash detected in log"
    grep -iE 'segfault|panic|abort|SIGSEGV|SIGABRT|unreachable' "$LOG" | tail -5
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: no crashes"
    PASS=$((PASS + 1))
  fi
  sleep 1
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed (of $CYCLES cycles) ==="
[ $FAIL -eq 0 ]
