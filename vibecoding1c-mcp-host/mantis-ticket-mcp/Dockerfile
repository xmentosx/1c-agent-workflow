FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV MANTIS_MCP_HOST=0.0.0.0
ENV MANTIS_MCP_PORT=8000
ENV MANTIS_ATTACHMENT_CACHE_PATH=/data/attachments

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tesseract-ocr \
        tesseract-ocr-eng \
        tesseract-ocr-rus \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY server.py /app/server.py
VOLUME ["/data/attachments"]

CMD ["python", "/app/server.py"]
