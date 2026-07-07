FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV BOOKSTACK_MCP_HOST=0.0.0.0
ENV BOOKSTACK_MCP_PORT=8000
ENV BOOKSTACK_CACHE_PATH=/data/bookstack-cache.sqlite
ENV MODEL_CACHE_DIR=/app/model_cache
ENV SENTENCE_TRANSFORMERS_HOME=/app/model_cache

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY server.py /app/server.py
VOLUME ["/data", "/app/model_cache"]

CMD ["python", "/app/server.py"]
