ARG BASE_IMAGE=comol/1c-code-checker@sha256:d598f990de043c211a3c09e6db0d4490fd91dcfb0cfd0708ab629e3bcd27118e
FROM ${BASE_IMAGE}

USER root
COPY codechecker-beta-overlay/patch_mcp_server.py /tmp/itl-fetch-tests/patch_mcp_server.py
COPY codechecker-beta-overlay/test_fetch_completion.py /tmp/itl-fetch-tests/test_fetch_completion.py
COPY codechecker-beta-overlay/patch_fastmcp_lifecycle.py /tmp/itl-fetch-tests/patch_fastmcp_lifecycle.py
COPY codechecker-beta-overlay/test_fastmcp_lifecycle.py /tmp/itl-fetch-tests/test_fastmcp_lifecycle.py
COPY codechecker-beta-overlay/fetch_completion.py /app/MCP_1copilot/fetch_completion.py
COPY codechecker-overlay/observability.py /app/MCP_1copilot/observability.py
RUN python /tmp/itl-fetch-tests/patch_mcp_server.py && python /tmp/itl-fetch-tests/patch_fastmcp_lifecycle.py && PYTHONPATH=/app/MCP_1copilot:/app python /tmp/itl-fetch-tests/test_fetch_completion.py --native && PYTHONPATH=/app python /tmp/itl-fetch-tests/test_fastmcp_lifecycle.py --native && rm -rf /tmp/itl-fetch-tests
USER appuser
