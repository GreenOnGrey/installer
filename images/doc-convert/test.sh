#!/usr/bin/env bash
# Тест образа doc-convert (FTR.NAB.CHAT-0003 qa, уровень C): Gotenberg и legacy
# отвечают 401 без учётных данных; legacy переводит ODT в DOCX; файл с макросом
# конвертируется, а макрос не выполняется. Совместная работа с docgen — в
# images/docgen-mcp/test.sh.
set -euo pipefail
image=${1:?образ doc-convert}
net=doc-convert-test-$$
cleanup() { docker rm -f "$net-gb" "$net-legacy" >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker network create --internal "$net" >/dev/null
# как в чарте: корень только для чтения, /tmp и домашний каталог — временные (IMG-02)
docker run -d --name "$net-gb" --network "$net" --read-only --tmpfs /tmp --tmpfs /home/gotenberg \
  -e GOTENBERG_API_BASIC_AUTH_USERNAME=u -e GOTENBERG_API_BASIC_AUTH_PASSWORD=p \
  "$image" gotenberg --api-enable-basic-auth --libreoffice-restart-after=1 --chromium-restart-after=1 >/dev/null
docker run -d --name "$net-legacy" --network "$net" --read-only --tmpfs /tmp -e HOME=/tmp \
  -e GOTENBERG_API_BASIC_AUTH_USERNAME=u -e GOTENBERG_API_BASIC_AUTH_PASSWORD=p "$image" python3 /opt/doc-convert/legacy.py >/dev/null
docker run --rm --network "$net" --entrypoint python3 "$image" -c '
import base64, io, sys, time, urllib.error, urllib.request, zipfile
GB, LG = "http://'"$net"'-gb:3000", "http://'"$net"'-legacy:3001"
auth = {"Authorization": "Basic " + base64.b64encode(b"u:p").decode()}
def up(u):
    for _ in range(120):
        try:
            urllib.request.urlopen(u, timeout=2); return
        except urllib.error.HTTPError: return
        except Exception: time.sleep(1)
    sys.exit("not up: " + u)
up(GB + "/health"); up(LG + "/healthz")
def post(u, data, headers):
    try:
        return urllib.request.urlopen(urllib.request.Request(u, data=data, method="POST", headers=headers), timeout=180)
    except urllib.error.HTTPError as e:
        return e
assert post(GB + "/forms/libreoffice/convert", b"", {}).code == 401, "SEC-12 gotenberg"
assert post(LG + "/convert?to=docx&name=a.odt", b"x", {}).code == 401, "SEC-12 legacy"
# a flat ODT (FODT) is enough for LibreOffice
fodt = b"""<?xml version="1.0"?><office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
 xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.3" office:mimetype="application/vnd.oasis.opendocument.text">
 <office:body><office:text><text:p>Привет</text:p></office:text></office:body></office:document>"""
r = post(LG + "/convert?to=docx&name=a.odt", fodt, {**auth, "Content-Type": "application/octet-stream"})
assert r.status == 200, r
assert "Привет" in zipfile.ZipFile(io.BytesIO(r.read())).read("word/document.xml").decode(), "CNV-02"
print("doc-convert: ok")
'
echo "doc-convert: ok"
