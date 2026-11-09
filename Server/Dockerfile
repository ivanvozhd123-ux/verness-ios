FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt && useradd --create-home --uid 10001 verness
ENV PATH="/opt/venv/bin:$PATH"
WORKDIR /app
COPY server.py /app/server.py
USER verness
EXPOSE 8766
CMD ["python3", "/app/server.py", "--host", "0.0.0.0"]
