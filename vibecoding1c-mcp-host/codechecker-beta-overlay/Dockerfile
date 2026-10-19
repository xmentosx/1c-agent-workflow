ARG BASE_IMAGE=comol/1c-code-checker@sha256:7ce11d25bfc0f662f8e425ca7dbb6eeeb2f4d0dbca31da68d0138c41ddba8cb3
FROM ${BASE_IMAGE}

USER root
COPY codechecker-beta-overlay/patch_mcp_server.py /tmp/itl-fetch-tests/patch_mcp_server.py
COPY codechecker-beta-overlay/test_fetch_completion.py /tmp/itl-fetch-tests/test_fetch_completion.py
COPY codechecker-beta-overlay/fetch_completion.py /app/MCP_1copilot/fetch_completion.py
COPY codechecker-overlay/observability.py /app/MCP_1copilot/observability.py
RUN python /tmp/itl-fetch-tests/patch_mcp_server.py && PYTHONPATH=/app/MCP_1copilot:/app python /tmp/itl-fetch-tests/test_fetch_completion.py --native && rm -rf /tmp/itl-fetch-tests
USER appuser
