FROM comol/1c-code-checker@sha256:b5e4d03f15ca91cfd886b5b81689caddc1d3d472838bf77582345e58b466cee0

USER root

COPY retry_policy.py /app/MCP_1copilot/retry_policy.py
COPY observability.py /app/MCP_1copilot/observability.py
COPY patch_mcp_server.py /tmp/patch_mcp_server.py
RUN python /tmp/patch_mcp_server.py && rm /tmp/patch_mcp_server.py

USER appuser
