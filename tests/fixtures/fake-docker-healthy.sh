#!/usr/bin/env bash
case "${1:-}" in
  info) exit 0 ;;
  compose) [[ "${2:-}" == version ]] && { echo 'Docker Compose version v5.5.0'; exit 0; } ;;
esac
exit 1
