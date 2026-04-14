#!/usr/bin/env bash
set -Eeuo pipefail

# Safe deploy helper:
# 1) Waits until GHCR sha-images are available
# 2) Pulls those exact images
# 3) Retags them as :latest for compose files pinned to latest
# 4) Recreates only requested services and waits for health

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-20}"

BACKEND_SHA="${BACKEND_SHA:-}"
FRONTEND_SHA="${FRONTEND_SHA:-}"
MD2GOST_SHA="${MD2GOST_SHA:-}"
DOCX2MD_SHA="${DOCX2MD_SHA:-}"
TELEGRAM_SHA="${TELEGRAM_SHA:-}"

print_usage() {
  cat <<'EOF'
Usage:
  deploy_wait_for_ghcr.sh [options]

Options:
  --project-dir <path>        Directory with docker-compose file (default: current dir)
  --compose-file <path>       Compose file name/path relative to project dir (default: docker-compose.yml)
  --backend-sha <sha|sha-...> Backend image SHA tag suffix to deploy
  --frontend-sha <sha|sha-...> Frontend image SHA tag suffix to deploy
  --md2gost-sha <sha|sha-...> md2gost image SHA tag suffix to deploy
  --docx2md-sha <sha|sha-...> docx2md image SHA tag suffix to deploy
  --telegram-sha <sha|sha-...> Telegram image SHA tag suffix to deploy
  --timeout-seconds <n>       Max wait time per image (default: 1800)
  --poll-interval <n>         Poll interval in seconds (default: 20)
  --help                      Show help

Examples:
  ./scripts/deploy_wait_for_ghcr.sh \
    --project-dir /@docker/data/@GostForge \
    --compose-file docker-compose.yml \
    --backend-sha 9f91425 \
    --frontend-sha fbf3fae
EOF
}

normalize_tag() {
  local value="$1"
  if [[ "$value" == sha-* ]]; then
    printf '%s' "$value"
  else
    printf 'sha-%s' "$value"
  fi
}

wait_for_image() {
  local image="$1"
  local start_ts now elapsed

  start_ts=$(date +%s)
  while true; do
    if docker pull "$image" >/dev/null 2>&1; then
      echo "[ok] Image is ready: $image"
      return 0
    fi

    now=$(date +%s)
    elapsed=$((now - start_ts))
    if (( elapsed >= TIMEOUT_SECONDS )); then
      echo "[error] Timed out waiting for image: $image" >&2
      return 1
    fi

    echo "[wait] $image is not ready yet (${elapsed}s/${TIMEOUT_SECONDS}s), retry in ${POLL_INTERVAL_SECONDS}s"
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

retag_latest() {
  local repo="$1"
  local sha_input="$2"
  local tag sha_image latest_image

  tag=$(normalize_tag "$sha_input")
  sha_image="ghcr.io/gostforge/${repo}:${tag}"
  latest_image="ghcr.io/gostforge/${repo}:latest"

  wait_for_image "$sha_image"
  docker tag "$sha_image" "$latest_image"
  echo "[ok] Retagged $sha_image -> $latest_image"
}

wait_for_container_healthy() {
  local container_name="$1"
  local start_ts now elapsed raw

  start_ts=$(date +%s)
  while true; do
    raw=$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || true)

    if [[ "$raw" == "running|healthy" ]] || [[ "$raw" == "running|none" ]]; then
      echo "[ok] Container healthy/running: $container_name ($raw)"
      return 0
    fi

    if [[ "$raw" == "exited|"* ]] || [[ "$raw" == "dead|"* ]]; then
      echo "[error] Container is not running: $container_name ($raw)" >&2
      docker logs --tail 80 "$container_name" || true
      return 1
    fi

    now=$(date +%s)
    elapsed=$((now - start_ts))
    if (( elapsed >= TIMEOUT_SECONDS )); then
      echo "[error] Timed out waiting for container: $container_name (last: ${raw:-missing})" >&2
      docker logs --tail 80 "$container_name" || true
      return 1
    fi

    echo "[wait] Waiting for $container_name (${elapsed}s/${TIMEOUT_SECONDS}s), current: ${raw:-missing}"
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir)
      PROJECT_DIR="$2"
      shift 2
      ;;
    --compose-file)
      COMPOSE_FILE="$2"
      shift 2
      ;;
    --backend-sha)
      BACKEND_SHA="$2"
      shift 2
      ;;
    --frontend-sha)
      FRONTEND_SHA="$2"
      shift 2
      ;;
    --md2gost-sha)
      MD2GOST_SHA="$2"
      shift 2
      ;;
    --docx2md-sha)
      DOCX2MD_SHA="$2"
      shift 2
      ;;
    --telegram-sha)
      TELEGRAM_SHA="$2"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --poll-interval)
      POLL_INTERVAL_SECONDS="$2"
      shift 2
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

services_to_restart=()
containers_to_check=()

if [[ -n "$BACKEND_SHA" ]]; then
  retag_latest "backend" "$BACKEND_SHA"
  services_to_restart+=("backend")
  containers_to_check+=("gostforge-backend")
fi

if [[ -n "$FRONTEND_SHA" ]]; then
  retag_latest "frontend" "$FRONTEND_SHA"
  services_to_restart+=("frontend")
  containers_to_check+=("gostforge-frontend")
fi

if [[ -n "$MD2GOST_SHA" ]]; then
  retag_latest "md2gost" "$MD2GOST_SHA"
  services_to_restart+=("md2gost")
  containers_to_check+=("gostforge-md2gost")
fi

if [[ -n "$DOCX2MD_SHA" ]]; then
  retag_latest "docx2md" "$DOCX2MD_SHA"
  services_to_restart+=("docx2md")
  containers_to_check+=("gostforge-docx2md")
fi

if [[ -n "$TELEGRAM_SHA" ]]; then
  retag_latest "telegram" "$TELEGRAM_SHA"
  services_to_restart+=("telegram")
  containers_to_check+=("gostforge-telegram")
fi

if [[ ${#services_to_restart[@]} -eq 0 ]]; then
  echo "[error] Nothing to deploy: provide at least one --*-sha argument" >&2
  exit 1
fi

cd "$PROJECT_DIR"
echo "[info] Recreating services: ${services_to_restart[*]}"
docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "${services_to_restart[@]}"

for container in "${containers_to_check[@]}"; do
  wait_for_container_healthy "$container"
done

echo "[done] Deployment completed successfully"
