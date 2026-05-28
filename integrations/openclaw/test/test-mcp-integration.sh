#!/usr/bin/env bash
set -euo pipefail

AGENTMEMORY_URL="${AGENTMEMORY_URL:-http://agentmemory:3111}"
AGENTMEMORY_SECRET="${AGENTMEMORY_SECRET:-sk-local}"
MCP_COMMAND="${MCP_COMMAND:-agentmemory-mcp}"
TIMEOUT_SECS="${TIMEOUT_SECS:-10}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
RESULTS=()

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
BOLD="\033[1m"
RESET="\033[0m"

log_pass() { RESULTS+=("${GREEN}PASS${RESET} | $1"); PASS_COUNT=$((PASS_COUNT + 1)); }
log_fail() { RESULTS+=("${RED}FAIL${RESET} | $1"); FAIL_COUNT=$((FAIL_COUNT + 1)); }
log_skip() { RESULTS+=("${YELLOW}SKIP${RESET} | $1"); SKIP_COUNT=$((SKIP_COUNT + 1)); }
section()  { echo -e "\n${CYAN}${BOLD}--- $1 ---${RESET}"; }

has_jq() { command -v jq &>/dev/null; }
has_timeout() { command -v timeout &>/dev/null; }

json_val() {
  local input="$1" key="$2"
  if has_jq; then
    echo "$input" | jq -r "$key" 2>/dev/null || echo ""
  else
    echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(${key#.}.format(**{'d':d}),default=str))" 2>/dev/null || echo ""
  fi
}

extract_json_field() {
  local input="$1" key="$2"
  if has_jq; then
    echo "$input" | jq -r ".$key" 2>/dev/null || echo ""
  else
    echo "$input" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1
  fi
}

extract_json_nested() {
  local input="$1" path="$2"
  if has_jq; then
    echo "$input" | jq -r ".$path" 2>/dev/null || echo ""
  else
    local py_path=$(echo "$path" | sed 's/\./\]\[\"/g; s/^/\[\"/; s/$/\"]/')
    echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d${py_path})" 2>/dev/null || echo ""
  fi
}

extract_result_text() {
  local input="$1"
  local text=""
  if has_jq; then
    text=$(echo "$input" | jq -r '.result.content[0].text' 2>/dev/null || echo "")
  else
    text=$(echo "$input" | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  fi
  echo "$text"
}

run_with_timeout() {
  local secs="$1"; shift
  if has_timeout; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

now_ms() {
  python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || date +%s 2>/dev/null || echo "0"
}

curl_status() {
  local url="$1"; shift
  local out
  out=$(run_with_timeout 5 curl -s -o /dev/null -w "%{http_code}" "$@" "${url}" 2>/dev/null) && echo "$out" || echo "000"
}

send_mcp() {
  local init_id="1"
  local input=""
  local first=true
  while IFS= read -r line; do
    if $first; then
      input="${line}"
      first=false
    else
      input="${input}"$'\n'"${line}"
    fi
  done

  printf '%s\n' "$input" | AGENTMEMORY_URL="$AGENTMEMORY_URL" AGENTMEMORY_SECRET="$AGENTMEMORY_SECRET" AGENTMEMORY_FORCE_PROXY=1 run_with_timeout "$TIMEOUT_SECS" "$MCP_COMMAND" 2>/dev/null || true
}

send_mcp_raw() {
  printf '%s' "$1" | AGENTMEMORY_URL="$AGENTMEMORY_URL" AGENTMEMORY_SECRET="$AGENTMEMORY_SECRET" AGENTMEMORY_FORCE_PROXY=1 run_with_timeout "$TIMEOUT_SECS" "$MCP_COMMAND" 2>/dev/null || true
}

echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD} agentmemory MCP Integration Test${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo -e "  URL:     ${AGENTMEMORY_URL}"
echo -e "  Secret:  ${AGENTMEMORY_SECRET:0:4}****"
echo -e "  MCP cmd: ${MCP_COMMAND}"
echo -e ""

if ! command -v "$MCP_COMMAND" &>/dev/null && ! command -v node &>/dev/null; then
  echo -e "${RED}ERROR: Neither '${MCP_COMMAND}' nor 'node' found in PATH${RESET}"
  echo -e "  Run: npm i -g @agentmemory/mcp"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════
section "Phase 1: REST Connectivity"

TEST="1.1 livez endpoint (no auth)"
STATUS=$(curl_status "${AGENTMEMORY_URL}/agentmemory/livez")
if [ "$STATUS" = "200" ]; then
  log_pass "$TEST (HTTP $STATUS)"
else
  log_fail "$TEST (HTTP $STATUS, expected 200)"
fi

TEST="1.2 livez endpoint (with auth)"
STATUS=$(curl_status "${AGENTMEMORY_URL}/agentmemory/livez" -H "Authorization: Bearer ${AGENTMEMORY_SECRET}")
if [ "$STATUS" = "200" ]; then
  log_pass "$TEST (HTTP $STATUS)"
else
  log_fail "$TEST (HTTP $STATUS, expected 200)"
fi

TEST="1.3 health endpoint"
BODY=$(run_with_timeout 5 curl -s -H "Authorization: Bearer ${AGENTMEMORY_SECRET}" "${AGENTMEMORY_URL}/agentmemory/health" 2>/dev/null || echo "")
STATUS=$(curl_status "${AGENTMEMORY_URL}/agentmemory/health" -H "Authorization: Bearer ${AGENTMEMORY_SECRET}")
if [ "$STATUS" = "200" ] && [ -n "$BODY" ]; then
  log_pass "$TEST (HTTP $STATUS)"
else
  log_fail "$TEST (HTTP $STATUS)"
fi

# ═══════════════════════════════════════════════════════════════
section "Phase 2: MCP Protocol Handshake"

INIT_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"openclaw-test","version":"1.0.0"}}}'

TEST="2.1 MCP initialize handshake"
RESP=$(send_mcp_raw "$INIT_REQ")
if [ -z "$RESP" ]; then
  log_fail "$TEST (no response)"
else
  PROTO=$(extract_json_nested "$RESP" "result.protocolVersion")
  SNAME=$(extract_json_nested "$RESP" "result.serverInfo.name")
  if [ "$PROTO" = "2024-11-05" ] && [ "$SNAME" = "agentmemory" ]; then
    log_pass "$TEST (protocol=$PROTO, server=$SNAME)"
  else
    log_fail "$TEST (protocol=$PROTO, server=$SNAME, expected 2024-11-05/agentmemory)"
  fi
fi

TEST="2.2 MCP initialize latency < 3s"
START_MS=$(now_ms)
RESP=$(send_mcp_raw "$INIT_REQ")
END_MS=$(now_ms)
if [ "$START_MS" != "0" ] && [ "$END_MS" != "0" ]; then
  ELAPSED=$((END_MS - START_MS))
  if [ "$ELAPSED" -ge 0 ] && [ "$ELAPSED" -lt 3000 ]; then
    log_pass "$TEST (${ELAPSED}ms)"
  elif [ "$ELAPSED" -lt 0 ]; then
    log_skip "$TEST (timer resolution insufficient)"
  else
    log_fail "$TEST (${ELAPSED}ms >= 3000ms)"
  fi
else
  log_skip "$TEST (no timer available)"
fi

# ═══════════════════════════════════════════════════════════════
section "Phase 3: tools/list"

MCP_SESSION=$(printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"openclaw-test","version":"1.0.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')

TEST="3.1 tools/list returns tools"
RESP=$(send_mcp_raw "$MCP_SESSION")
if [ -z "$RESP" ]; then
  log_fail "$TEST (no response)"
else
  LAST_LINE=$(printf '%s' "$RESP" | tail -1)
  TOOL_COUNT=""
  if has_jq; then
    TOOL_COUNT=$(echo "$LAST_LINE" | jq '.result.tools | length' 2>/dev/null || echo "0")
  else
    TOOL_COUNT=$(echo "$LAST_LINE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['result']['tools']))" 2>/dev/null || echo "0")
  fi
  if [ "$TOOL_COUNT" -ge 7 ] 2>/dev/null; then
    log_pass "$TEST ($TOOL_COUNT tools)"
  else
    log_fail "$TEST (got $TOOL_COUNT tools, expected >= 7)"
  fi
fi

TEST="3.2 essential tools present (memory_save, memory_recall, memory_smart_search)"
if [ -n "$LAST_LINE" ]; then
  FOUND_SAVE=0 FOUND_RECALL=0 FOUND_SMART=0
  if has_jq; then
    NAMES=$(echo "$LAST_LINE" | jq -r '.result.tools[].name' 2>/dev/null)
  else
    NAMES=$(echo "$LAST_LINE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(t['name'] for t in d['result']['tools']))" 2>/dev/null)
  fi
  echo "$NAMES" | grep -q "memory_save"         && FOUND_SAVE=1
  echo "$NAMES" | grep -q "memory_recall"       && FOUND_RECALL=1
  echo "$NAMES" | grep -q "memory_smart_search" && FOUND_SMART=1
  if [ "$FOUND_SAVE" = "1" ] && [ "$FOUND_RECALL" = "1" ] && [ "$FOUND_SMART" = "1" ]; then
    log_pass "$TEST"
  else
    log_fail "$TEST (save=$FOUND_SAVE recall=$FOUND_RECALL smart=$FOUND_SMART)"
  fi
else
  log_skip "$TEST (no tools/list response to inspect)"
fi

# ═══════════════════════════════════════════════════════════════
section "Phase 4: End-to-End save → recall"

TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
SAVE_CONTENT="openclaw-mcp-test-${TIMESTAMP}"

SAVE_SESSION=$(printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"openclaw-test","version":"1.0.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_save\",\"arguments\":{\"content\":\"${SAVE_CONTENT}\",\"type\":\"fact\",\"concepts\":[\"test\",\"openclaw\"]}}}")

TEST="4.1 memory_save"
RESP=$(send_mcp_raw "$SAVE_SESSION")
if [ -z "$RESP" ]; then
  log_fail "$TEST (no response)"
else
  LAST_LINE=$(printf '%s' "$RESP" | tail -1)
  TEXT=$(extract_result_text "$LAST_LINE")
  if echo "$TEXT" | grep -qi "saved\|id\|mem_"; then
    log_pass "$TEST (saved: ${SAVE_CONTENT:0:40})"
  else
    log_fail "$TEST (response: ${TEXT:0:80})"
  fi
fi

sleep 1

RECALL_SESSION=$(printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"openclaw-test","version":"1.0.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_recall\",\"arguments\":{\"query\":\"${SAVE_CONTENT}\",\"limit\":5}}}")

TEST="4.2 memory_recall finds saved content"
RESP=$(send_mcp_raw "$RECALL_SESSION")
if [ -z "$RESP" ]; then
  log_fail "$TEST (no response)"
else
  LAST_LINE=$(printf '%s' "$RESP" | tail -1)
  TEXT=$(extract_result_text "$LAST_LINE")
  if echo "$TEXT" | grep -q "$TIMESTAMP"; then
    log_pass "$TEST (found saved content)"
  else
    log_fail "$TEST (response did not contain saved content: ${TEXT:0:100})"
  fi
fi

# ═══════════════════════════════════════════════════════════════
section "Phase 5: REST direct MCP call"

TEST="5.1 POST /agentmemory/mcp/call (memory_sessions)"
BODY=$(run_with_timeout 5 curl -s -X POST \
  -H "Authorization: Bearer ${AGENTMEMORY_SECRET}" \
  -H "Content-Type: application/json" \
  -d '{"name":"memory_sessions","arguments":{"limit":3}}' \
  "${AGENTMEMORY_URL}/agentmemory/mcp/call" 2>/dev/null || echo "")
if [ -n "$BODY" ] && echo "$BODY" | grep -q "content"; then
  log_pass "$TEST (got response)"
else
  log_fail "$TEST (response: ${BODY:0:100})"
fi

TEST="5.2 POST /agentmemory/mcp/call (memory_audit)"
BODY=$(run_with_timeout 5 curl -s -X POST \
  -H "Authorization: Bearer ${AGENTMEMORY_SECRET}" \
  -H "Content-Type: application/json" \
  -d '{"name":"memory_audit","arguments":{"limit":5}}' \
  "${AGENTMEMORY_URL}/agentmemory/mcp/call" 2>/dev/null || echo "")
if [ -n "$BODY" ] && echo "$BODY" | grep -q "content"; then
  log_pass "$TEST (got response)"
else
  log_fail "$TEST (response: ${BODY:0:100})"
fi

# ═══════════════════════════════════════════════════════════════
section "Phase 6: Proxy generic path (non-basic tool)"

TEST="6.1 memory_export via MCP shim"
EXPORT_SESSION=$(printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"openclaw-test","version":"1.0.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_export","arguments":{}}}')
RESP=$(send_mcp_raw "$EXPORT_SESSION")
if [ -z "$RESP" ]; then
  log_fail "$TEST (no response)"
else
  LAST_LINE=$(printf '%s' "$RESP" | tail -1)
  TEXT=$(extract_result_text "$LAST_LINE")
  if echo "$TEXT" | grep -q "version"; then
    log_pass "$TEST (export returned versioned payload)"
  else
    log_fail "$TEST (response: ${TEXT:0:80})"
  fi
fi

# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD} Test Results${RESET}"
echo -e "${BOLD}========================================${RESET}"
for r in "${RESULTS[@]}"; do
  echo -e "  $r"
done
echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
echo -e "  ${GREEN}PASS${RESET}: ${PASS_COUNT}  ${RED}FAIL${RESET}: ${FAIL_COUNT}  ${YELLOW}SKIP${RESET}: ${SKIP_COUNT}  Total: ${TOTAL}"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo -e "${RED}${BOLD}Some tests failed.${RESET}"
  exit 1
else
  echo -e "${GREEN}${BOLD}All tests passed! OpenClaw <-> agentmemory MCP integration is working.${RESET}"
  exit 0
fi
