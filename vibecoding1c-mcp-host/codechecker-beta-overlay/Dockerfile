ARG BASE_IMAGE=comol/1c-code-checker@sha256:d0e14e177e6918f61795c1a46910dbf58d1a3f0edced6467c226c3fa9bc58cae
FROM ${BASE_IMAGE}

USER root
COPY patch_mcp_server.py /tmp/patch_beta_mcp_server.py
RUN python /tmp/patch_beta_mcp_server.py && rm /tmp/patch_beta_mcp_server.py
USER appuser
