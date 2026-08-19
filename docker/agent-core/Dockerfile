FROM python:3.12.11-slim-bookworm
ARG TARGETARCH
LABEL org.opencontainers.image.title="Offline AI Agent Core" org.opencontainers.image.version="1.0.0"
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
RUN case "$TARGETARCH" in arm64|amd64) ;; *) exit 1 ;; esac && sed -i 's#http://deb.debian.org#https://deb.debian.org#g' /etc/apt/sources.list.d/debian.sources && apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY agent-core/requirements.txt ./requirements.txt
RUN pip install --requirement requirements.txt
COPY agent-core/app ./app
RUN useradd --system --uid 10001 --no-create-home agent
USER 10001
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
