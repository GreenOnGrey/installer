#!/usr/bin/env bash
# Тест образа workspace-mcp (FTR.NAB.CMN-0006 IMG-02, IMG-03):
#   - в режиме стенда (внешний OAuth, без хранения состояния) запрос без токена
#     Google получает 401, процесс не от root, корневая ФС только для чтения;
#   - с флагами стенда (--tools gmail --read-only, вложения закрыты) в tools/list
#     только поиск, чтение и списки: нет отправки, черновиков, удаления, меток,
#     фильтров и вложений. Список читается по stdio: он не требует токена.
set -euo pipefail
image=${1:?образ}
docker run --rm --read-only --tmpfs /tmp -e HOME=/tmp \
  -e MCP_ENABLE_OAUTH21=true -e EXTERNAL_OAUTH21_PROVIDER=true -e WORKSPACE_MCP_STATELESS_MODE=true \
  -e GOOGLE_OAUTH_CLIENT_ID=test.apps.googleusercontent.com -e WORKSPACE_MCP_HOST=127.0.0.1 -e WORKSPACE_MCP_PORT=8000 \
  -e WORKSPACE_MCP_DISABLED_TOOLS=get_gmail_attachment_content \
  --entrypoint python "$image" -c '
import json, os, re, subprocess, sys, time, urllib.error, urllib.request
assert os.getuid() != 0, "runs as root"
p = subprocess.Popen(["workspace-mcp", "--transport", "streamable-http", "--tools", "gmail", "--read-only"],
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}}).encode()
h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
code = None
for _ in range(60):
    try:
        urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8000/mcp", body, h), timeout=10)
        code = 200
        break
    except urllib.error.HTTPError as e:
        code = e.code
        break
    except Exception:
        time.sleep(1)
p.terminate()
out = p.communicate(timeout=10)[0]
if code != 401:
    sys.exit(f"without a token: expected 401, got {code}\n{out[-2000:]}")

# список инструментов: те же флаги, транспорт stdio
s = subprocess.Popen(["workspace-mcp", "--transport", "stdio", "--tools", "gmail", "--read-only"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                     env={**os.environ, "MCP_ENABLE_OAUTH21": "false", "EXTERNAL_OAUTH21_PROVIDER": "false"})
def send(msg):
    s.stdin.write(json.dumps(msg) + "\n"); s.stdin.flush()
def answer(i):
    while True:
        line = s.stdout.readline()
        if not line:
            sys.exit("stdio server closed")
        m = json.loads(line)
        if m.get("id") == i:
            return m
send(json.loads(body))
answer(1)
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
names = sorted(t["name"] for t in answer(2)["result"]["tools"])
s.terminate()
# изменяющие инструменты (send_, draft_, modify_, manage_, create_, delete_…) не начинаются с search_/get_/list_
bad = [n for n in names if not re.match(r"(search|get|list)_", n) or "attachment" in n]
if bad or not names:
    sys.exit(f"forbidden tools {bad} in {names}")
print("workspace-mcp: ok, 401 without a token; tools:", ", ".join(names))
'
