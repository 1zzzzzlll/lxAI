#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

expected_arch=$(target_arch)
platform="linux/$expected_arch"
shopt -s nullglob
archives=("$PROJECT_DIR"/images/*.tar)
((${#archives[@]} > 0)) || die 'no image archives found under images/'
for archive in "${archives[@]}"; do
  info "Loading $(basename "$archive")"
  if docker load --help 2>&1 | grep -q -- '--platform'; then
    docker load --platform "$platform" --input "$archive"
  else
    docker load --input "$archive"
  fi
done

while IFS= read -r image; do
  [[ -n "$image" ]] || continue
  arch=$(docker image inspect --platform "$platform" "$image" --format '{{.Architecture}}' 2>/dev/null || docker image inspect "$image" --format '{{.Architecture}}' 2>/dev/null || true)
  [[ "$arch" == "$expected_arch" ]] || die "image $image has architecture ${arch:-missing}, expected $expected_arch"
  pass "$image Architecture=$expected_arch"
done < <(compose config --images | sort -u)
