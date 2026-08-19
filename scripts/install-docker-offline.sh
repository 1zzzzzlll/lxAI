#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'offline Docker installation must run as root'

runtime_dir="$PROJECT_DIR/runtime/docker"
engine_version=$(awk -F= '$1=="docker-engine" {print $2}' "$PROJECT_DIR/VERSION")
compose_version=$(awk -F= '$1=="docker-compose" {print $2}' "$PROJECT_DIR/VERSION")
[[ -n "$engine_version" && -n "$compose_version" ]] || die 'Docker versions are missing from VERSION'

arch=$(target_arch)
case "$arch" in
  arm64) compose_arch=aarch64 ;;
  amd64) compose_arch=x86_64 ;;
  *) die "unsupported Docker architecture: $arch" ;;
esac

engine_archive="$runtime_dir/docker-${engine_version}.tgz"
compose_binary="$runtime_dir/docker-compose-linux-${compose_arch}"
checksum_file="$runtime_dir/checksums.sha256"
install_dir=${DOCKER_INSTALL_DIR:-/usr/local/bin}
compose_dir=${DOCKER_COMPOSE_PLUGIN_DIR:-/usr/local/lib/docker/cli-plugins}
docker_data_root=${DOCKER_DATA_ROOT:-${DATA_ROOT:-/TRS/lxAI}/docker-engine}
DOCKER_DATA_ROOT=$docker_data_root
validate_docker_data_root
docker_data_root=$DOCKER_DATA_ROOT

[[ "$install_dir" == /* && "$compose_dir" == /* && "$docker_data_root" == /* ]] || die 'Docker installation paths must be absolute'
for configured_path in "$install_dir" "$compose_dir" "$docker_data_root"; do
  [[ "$configured_path" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Docker installation paths may only contain letters, digits, dot, underscore, slash, and hyphen: $configured_path"
done
[[ -f "$checksum_file" ]] || die "offline Docker checksum file is missing: $checksum_file"
[[ -f "$compose_binary" ]] || die "offline Docker Compose binary is missing: $compose_binary"
(cd "$runtime_dir" && sha256sum -c checksums.sha256) || die 'offline Docker asset checksum validation failed'

install_compose() {
  mkdir -p "$install_dir" "$compose_dir"
  install -m 0755 "$compose_binary" "$compose_dir/docker-compose"
  ln -sfn "$compose_dir/docker-compose" "$install_dir/docker-compose"
  pass "Docker Compose $compose_version installed"
}

if command -v docker >/dev/null 2>&1; then
  install_compose
  exit 0
fi

[[ -f "$engine_archive" ]] || die "offline Docker Engine archive is missing: $engine_archive"
command -v tar >/dev/null 2>&1 || die 'tar is required to install Docker Engine'
command -v install >/dev/null 2>&1 || die 'install is required to install Docker Engine'

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
tar -xzf "$engine_archive" -C "$tmp_dir"
for binary in containerd containerd-shim-runc-v2 ctr docker docker-init docker-proxy dockerd runc; do
  [[ -x "$tmp_dir/docker/$binary" ]] || die "Docker archive is missing executable: $binary"
done

mkdir -p "$install_dir" "$docker_data_root" /var/log/offline-ai-docker
for binary in "$tmp_dir"/docker/*; do install -m 0755 "$binary" "$install_dir/$(basename "$binary")"; done
hash -r
install_compose

docker_service_command="$install_dir/dockerd --host=unix:///var/run/docker.sock --data-root=$docker_data_root"
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  unit_file=/etc/systemd/system/docker.service
  if [[ -e "$unit_file" ]]; then
    backup_file="${unit_file}.offline-ai-backup-$(date +%Y%m%d%H%M%S)"
    cp -a "$unit_file" "$backup_file"
    warn "Existing $unit_file backed up to $backup_file"
  fi
  sed \
    -e "s|@DOCKERD@|$install_dir/dockerd|g" \
    -e "s|@DATA_ROOT@|$docker_data_root|g" \
    "$PROJECT_DIR/runtime/docker/docker.service.template" > "$unit_file"
  chmod 0644 "$unit_file"
  systemctl daemon-reload
  if ! systemctl enable --now docker.service; then
    journalctl -u docker.service --no-pager -n 80 >&2 || true
    die 'systemd could not start the bundled Docker Engine'
  fi
elif [[ -d /etc/init.d ]]; then
  init_file=/etc/init.d/docker
  if [[ -e "$init_file" ]]; then
    backup_file="${init_file}.offline-ai-backup-$(date +%Y%m%d%H%M%S)"
    cp -a "$init_file" "$backup_file"
    warn "Existing $init_file backed up to $backup_file"
  fi
  sed \
    -e "s|@DOCKERD@|$install_dir/dockerd|g" \
    -e "s|@DATA_ROOT@|$docker_data_root|g" \
    "$PROJECT_DIR/runtime/docker/docker.init.template" > "$init_file"
  chmod 0755 "$init_file"
  if command -v update-rc.d >/dev/null 2>&1; then update-rc.d docker defaults; fi
  if command -v chkconfig >/dev/null 2>&1; then chkconfig --add docker; chkconfig docker on; fi
  "$init_file" start
else
  die "Docker binaries were installed, but no supported service manager was found. Start manually: $docker_service_command"
fi

deadline=$((SECONDS + 90))
until docker info >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    if command -v journalctl >/dev/null 2>&1; then journalctl -u docker.service --no-pager -n 80 >&2 || true; fi
    [[ -f /var/log/offline-ai-docker/dockerd.log ]] && tail -n 80 /var/log/offline-ai-docker/dockerd.log >&2 || true
    die 'offline Docker Engine was installed but the daemon did not become ready; check kernel/cgroup/iptables support'
  fi
  sleep 2
done

pass "Docker Engine $engine_version installed and running"
pass "Docker data root: $docker_data_root"
