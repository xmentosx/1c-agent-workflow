FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 SPPR_CONFIG=/config/reader.json
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY sppr_*.py server.py /app/
CMD ["python", "/app/server.py"]
