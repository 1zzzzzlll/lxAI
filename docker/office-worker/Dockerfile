FROM node:22.18.0-bookworm-slim AS node-runtime

FROM python:3.12.11-slim-bookworm
ARG TARGETARCH
LABEL org.opencontainers.image.title="Offline AI Office Worker" org.opencontainers.image.version="1.0.0"
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 NODE_PATH=/usr/local/lib/node_modules HOME=/tmp/office-home
WORKDIR /app
RUN case "$TARGETARCH" in arm64|amd64) ;; *) exit 1 ;; esac
COPY --from=node-runtime /usr/local /usr/local
RUN sed -i 's#http://deb.debian.org#https://deb.debian.org#g' /etc/apt/sources.list.d/debian.sources && apt-get update && apt-get install -y --no-install-recommends ca-certificates curl libreoffice libreoffice-writer libreoffice-calc libreoffice-impress fonts-noto-cjk fonts-noto-cjk-extra fonts-noto-core fonts-dejavu-core fontconfig poppler-utils pandoc && rm -rf /var/lib/apt/lists/* && fc-cache -f
COPY office-worker/requirements.txt ./requirements.txt
RUN pip install --requirement requirements.txt
RUN npm install --global pptxgenjs@3.12.0 docx@9.5.1 exceljs@4.4.0
COPY office-worker/app ./app
RUN groupadd --system --gid 20000 workspace && useradd --system --uid 10003 --gid 20000 --create-home --home-dir /tmp/office-home office && mkdir -p /workspace /templates /tmp/office-home && chown -R office:workspace /app /workspace /tmp/office-home
USER 10003
EXPOSE 8000
CMD ["sh", "-c", "umask 0002 && exec uvicorn app.main:app --host 0.0.0.0 --port 8000"]
