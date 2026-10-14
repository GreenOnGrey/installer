# workspace-mcp: Gmail только для чтения (FTR.NAB.CMN-0006 tech §2.7).
# Версия пакета — WORKSPACE_MCP_VERSION из config/versions.env, она же тег образа.
FROM python:3.12-slim-trixie
ARG VERSION
RUN test -n "$VERSION" && pip install --no-cache-dir "workspace-mcp==${VERSION}"
USER 10001
ENV HOME=/tmp
ENTRYPOINT ["workspace-mcp"]
