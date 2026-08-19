FROM node:22.18.0-bookworm-slim AS node-runtime

FROM python:3.12.11-slim-bookworm
ARG TARGETARCH
ARG KUBECTL_VERSION=v1.33.3
ARG HELM_VERSION=v3.18.4
LABEL org.opencontainers.image.title="Offline AI Tool Runner" org.opencontainers.image.version="1.0.0"
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 NODE_PATH=/usr/local/lib/node_modules
WORKDIR /app
RUN case "$TARGETARCH" in arm64|amd64) ;; *) exit 1 ;; esac
COPY --from=node-runtime /usr/local /usr/local
RUN sed -i 's#http://deb.debian.org#https://deb.debian.org#g' /etc/apt/sources.list.d/debian.sources && apt-get update && apt-get install -y --no-install-recommends bash ca-certificates curl wget jq git openssh-client rsync zip unzip gzip tar zstd openssl iputils-ping traceroute mtr-tiny netcat-openbsd dnsutils iproute2 procps findutils gawk sed grep default-mysql-client postgresql-client && rm -rf /var/lib/apt/lists/*
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" && chmod 0755 /usr/local/bin/kubectl && curl -fsSLo /tmp/helm.tar.gz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" && tar -xzf /tmp/helm.tar.gz -C /tmp && install -m 0755 "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm && rm -rf /tmp/helm.tar.gz "/tmp/linux-${TARGETARCH}"
COPY tool-runner/requirements.txt ./requirements.txt
RUN pip install --requirement requirements.txt
RUN npm install --global typescript@5.9.2 tsx@4.20.3 axios@1.11.0 lodash@4.17.21 xlsx@0.18.5 exceljs@4.4.0 pptxgenjs@3.12.0 docx@9.5.1 jszip@3.10.1 cheerio@1.1.2
COPY tool-runner/app ./app
RUN groupadd --system --gid 20000 workspace && useradd --system --uid 10002 --gid 20000 --create-home --home-dir /tmp/tool-home tool && mkdir -p /workspace /secrets/ssh && chown -R tool:workspace /app /workspace /tmp/tool-home
USER 10002
EXPOSE 8000
CMD ["sh", "-c", "umask 0002 && exec uvicorn app.main:app --host 0.0.0.0 --port 8000"]
