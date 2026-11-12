ARG BASE_IMAGE=itl/cognee-qual:1.6.5-20261019-a8bd3718
FROM ${BASE_IMAGE}

USER root
COPY patch_image.py recall_policy.py /opt/itl/recall-build/
RUN python /opt/itl/recall-build/patch_image.py
LABEL itl.cognee.recall-policy="chunks-v1"
USER cognee
