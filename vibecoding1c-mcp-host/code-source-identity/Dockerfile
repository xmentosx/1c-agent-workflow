# An isolated candidate only. Building it does not replace or reindex a service.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
LABEL org.itland.code-source-identity.contract="1"
COPY patch.py source_identity.py /tmp/itl-source-identity/
RUN python /tmp/itl-source-identity/patch.py /app/src
