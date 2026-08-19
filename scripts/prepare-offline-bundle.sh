#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

IMAGE_ARCH=${TARGET_ARCH:-${IMAGE_ARCH:-arm64}}
case "$IMAGE_ARCH" in
  arm64|aarch64) IMAGE_ARCH=arm64; BUNDLE_ARCH=arm64 ;;
  amd64|x86_64) IMAGE_ARCH=amd64; BUNDLE_ARCH=x86_64 ;;
  *) die "unsupported TARGET_ARCH: $IMAGE_ARCH" ;;
esac
PLATFORM="linux/$IMAGE_ARCH"
VERSION_NUMBER=$(awk -F= '$1=="offline-ai-platform" {print $2}' "$PROJECT_DIR/VERSION")
DOCKER_ENGINE_VERSION=$(awk -F= '$1=="docker-engine" {print $2}' "$PROJECT_DIR/VERSION")
DOCKER_COMPOSE_VERSION=$(awk -F= '$1=="docker-compose" {print $2}' "$PROJECT_DIR/VERSION")
JQ_VERSION=$(awk -F= '$1=="jq" {print $2}' "$PROJECT_DIR/VERSION")
[[ -n "$DOCKER_ENGINE_VERSION" && -n "$DOCKER_COMPOSE_VERSION" && -n "$JQ_VERSION" ]] || die 'Offline runtime versions are missing from VERSION'
DIST_ROOT="$PROJECT_DIR/dist"
BUNDLE_NAME="offline-ai-$BUNDLE_ARCH"
BUNDLE_DIR="$DIST_ROOT/$BUNDLE_NAME"
OUTPUT="$DIST_ROOT/${BUNDLE_NAME}-v${VERSION_NUMBER}.tar.zst"
IMAGES=(
  nginx:1.28.0-bookworm
  ghcr.io/open-webui/open-webui:v0.9.5
  "offline-ai/agent-core:1.0.0-$IMAGE_ARCH"
  "offline-ai/office-worker:1.0.0-$IMAGE_ARCH"
  "offline-ai/tool-runner:1.0.0-$IMAGE_ARCH"
  postgres:17.10-bookworm
  qdrant/qdrant:v1.18.2
)

command -v docker >/dev/null || die 'Docker is required'
docker info >/dev/null 2>&1 || die 'Docker daemon is unavailable'
docker buildx version >/dev/null 2>&1 || die 'docker buildx is required'
command -v zstd >/dev/null || die 'zstd is required'
command -v curl >/dev/null || die 'curl is required'

case "$IMAGE_ARCH" in
  arm64) DOCKER_STATIC_ARCH=aarch64; COMPOSE_ARCH=aarch64 ;;
  amd64) DOCKER_STATIC_ARCH=x86_64; COMPOSE_ARCH=x86_64 ;;
esac
DOCKER_ENGINE_SHA256=$(awk -F= -v arch="$IMAGE_ARCH" '$1=="docker-engine-sha256-" arch {print $2}' "$PROJECT_DIR/VERSION")
DOCKER_COMPOSE_SHA256=$(awk -F= -v arch="$IMAGE_ARCH" '$1=="docker-compose-sha256-" arch {print $2}' "$PROJECT_DIR/VERSION")
JQ_SHA256=$(awk -F= -v arch="$IMAGE_ARCH" '$1=="jq-sha256-" arch {print $2}' "$PROJECT_DIR/VERSION")
[[ "$DOCKER_ENGINE_SHA256" =~ ^[0-9a-f]{64}$ && "$DOCKER_COMPOSE_SHA256" =~ ^[0-9a-f]{64}$ && "$JQ_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "Offline runtime checksums are missing for $IMAGE_ARCH"
DOCKER_CACHE="$PROJECT_DIR/.cache/docker-runtime/$IMAGE_ARCH"
HOST_TOOLS_CACHE="$PROJECT_DIR/.cache/host-tools/$IMAGE_ARCH"
mkdir -p "$DOCKER_CACHE" "$HOST_TOOLS_CACHE"

download_verified_asset() {
  local url=$1
  local output=$2
  local expected=$3
  local actual=''
  if [[ -f "$output" ]]; then
    actual=$(sha256sum "$output" | awk '{print $1}')
  fi
  if [[ "${actual,,}" != "${expected,,}" ]]; then
    info "Downloading pinned offline runtime: $url"
    curl -fL --retry 4 --retry-all-errors -o "${output}.part" "$url"
    actual=$(sha256sum "${output}.part" | awk '{print $1}')
    [[ "${actual,,}" == "${expected,,}" ]] || die "checksum mismatch while downloading $url"
    mv -f "${output}.part" "$output"
  else
    pass "Reusing verified $(basename "$output")"
  fi
}

docker_archive="docker-${DOCKER_ENGINE_VERSION}.tgz"
compose_binary="docker-compose-linux-${COMPOSE_ARCH}"
download_verified_asset \
  "https://download.docker.com/linux/static/stable/${DOCKER_STATIC_ARCH}/${docker_archive}" \
  "$DOCKER_CACHE/$docker_archive" \
  "$DOCKER_ENGINE_SHA256"
download_verified_asset \
  "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/${compose_binary}" \
  "$DOCKER_CACHE/$compose_binary" \
  "$DOCKER_COMPOSE_SHA256"
download_verified_asset \
  "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${IMAGE_ARCH}" \
  "$HOST_TOOLS_CACHE/jq-linux-${IMAGE_ARCH}" \
  "$JQ_SHA256"

if [[ ! -f "$PROJECT_DIR/models/embedding/config.json" ]]; then
  info 'Downloading pinned embedding model in the connected preparation environment'
  host_model_dir="$PROJECT_DIR/models/embedding"
  if command -v cygpath >/dev/null 2>&1; then host_model_dir=$(cygpath -w "$host_model_dir"); fi
  MSYS_NO_PATHCONV=1 docker run --rm --platform "$PLATFORM" --mount "type=bind,source=${host_model_dir},target=/output" python:3.12.11-slim-bookworm sh -c "pip install --no-cache-dir 'huggingface_hub==0.34.3' && python -c \"from huggingface_hub import snapshot_download; snapshot_download(repo_id='BAAI/bge-small-zh-v1.5', revision='refs/heads/main', ignore_patterns=['pytorch_model.bin','*.h5','*.msgpack'], local_dir='/output')\""
fi

build_or_reuse() {
  local image=$1
  local dockerfile=$2
  local arch=''
  arch=$(docker image inspect --platform "$PLATFORM" "$image" --format '{{.Architecture}}' 2>/dev/null || true)
  if [[ "${FORCE_REBUILD:-0}" != 1 && "$arch" == "$IMAGE_ARCH" ]]; then
    pass "Reusing $image Architecture=$IMAGE_ARCH (set FORCE_REBUILD=1 to rebuild)"
    return
  fi
  info "Building $image for $PLATFORM"
  docker buildx build --platform "$PLATFORM" --pull --load --provenance=false -f "$dockerfile" -t "$image" "$PROJECT_DIR"
}

build_or_reuse "offline-ai/agent-core:1.0.0-$IMAGE_ARCH" "$PROJECT_DIR/docker/agent-core/Dockerfile"
build_or_reuse "offline-ai/office-worker:1.0.0-$IMAGE_ARCH" "$PROJECT_DIR/docker/office-worker/Dockerfile"
build_or_reuse "offline-ai/tool-runner:1.0.0-$IMAGE_ARCH" "$PROJECT_DIR/docker/tool-runner/Dockerfile"

for image in nginx:1.28.0-bookworm ghcr.io/open-webui/open-webui:v0.9.5 postgres:17.10-bookworm qdrant/qdrant:v1.18.2; do
  docker pull --platform "$PLATFORM" "$image"
done

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/images"
(cd "$PROJECT_DIR" && tar --exclude=.git --exclude=.env --exclude=config/deployment.env --exclude=dist --exclude=images --exclude=data --exclude=.cache '--exclude=.runtime-smoke*' --exclude=.venv-test --exclude=__pycache__ --exclude=.pytest_cache -cf - .) | (cd "$BUNDLE_DIR" && tar -xf -)
mkdir -p "$BUNDLE_DIR/runtime/docker"
install -m 0644 "$DOCKER_CACHE/$docker_archive" "$BUNDLE_DIR/runtime/docker/$docker_archive"
install -m 0755 "$DOCKER_CACHE/$compose_binary" "$BUNDLE_DIR/runtime/docker/$compose_binary"
(cd "$BUNDLE_DIR/runtime/docker" && sha256sum "$docker_archive" "$compose_binary" > checksums.sha256)
mkdir -p "$BUNDLE_DIR/runtime/host-tools"
install -m 0755 "$HOST_TOOLS_CACHE/jq-linux-${IMAGE_ARCH}" "$BUNDLE_DIR/runtime/host-tools/jq-linux-${IMAGE_ARCH}"
(cd "$BUNDLE_DIR/runtime/host-tools" && sha256sum "jq-linux-${IMAGE_ARCH}" > checksums.sha256)
printf '%s\n' "$IMAGE_ARCH" > "$BUNDLE_DIR/TARGET_ARCH"
sed -i "s/^IMAGE_ARCH=.*/IMAGE_ARCH=$IMAGE_ARCH/" "$BUNDLE_DIR/.env.example"
chmod +x "$BUNDLE_DIR"/*.sh "$BUNDLE_DIR"/scripts/*.sh "$BUNDLE_DIR"/tests/*.sh

: > "$BUNDLE_DIR/images/manifest.tsv"
for image in "${IMAGES[@]}"; do
  arch=$(docker image inspect --platform "$PLATFORM" "$image" --format '{{.Architecture}}')
  [[ "$arch" == "$IMAGE_ARCH" ]] || die "$image architecture is $arch, expected $IMAGE_ARCH"
  safe_name=$(sed 's#[/:]#_#g' <<<"$image")
  archive="images/${safe_name}.tar"
  docker save --platform "$PLATFORM" --output "$BUNDLE_DIR/$archive" "$image"
  image_id=$(docker image inspect --platform "$PLATFORM" "$image" --format '{{.Id}}')
  digest=$(docker image inspect --platform "$PLATFORM" "$image" --format '{{join .RepoDigests ","}}')
  printf '%s\t%s\t%s\t%s\t%s\n' "$image" "$arch" "$image_id" "$digest" "$archive" >> "$BUNDLE_DIR/images/manifest.tsv"
  pass "$image Architecture=$IMAGE_ARCH"
done

(cd "$BUNDLE_DIR" && sha256sum images/*.tar > checksums.sha256)
rm -f "$OUTPUT"
tar --zstd -cf "$OUTPUT" -C "$DIST_ROOT" "$BUNDLE_NAME"
bundle_checksum=$(sha256sum "$OUTPUT" | awk '{print $1}')
printf '%s  %s\n' "$bundle_checksum" "$(basename "$OUTPUT")" > "${OUTPUT}.sha256"
pass "Offline bundle: $OUTPUT"
