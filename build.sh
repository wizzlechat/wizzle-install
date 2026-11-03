#!/usr/bin/env bash
# Builds a versioned Wizzle bundle for NanoClaw or OpenClaw and the site files that serve it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="${1:-}"
runtime="${2:-nanoclaw}"
fork_skill="${WIZZLE_FORK_SKILL:-$HOME/Workspace/nanoclaw/.claude/skills/add-wizzle}"
openclaw_dir="${WIZZLE_OPENCLAW:-$here/../wizzle-openclaw}"
site="${WIZZLE_SITE:-$here/../wizzle-site}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$runtime" =~ ^(nanoclaw|openclaw)$ ]]; then
  echo 'Usage: ./build.sh <version> [nanoclaw|openclaw], for example ./build.sh 0.1.0 openclaw' >&2
  exit 64
fi

build_nanoclaw() {
  if [ ! -f "$fork_skill/SKILL.md" ]; then
    echo "No add-wizzle skill at $fork_skill" >&2
    exit 1
  fi
  if ! ls "$here"/patches/*.patch >/dev/null 2>&1; then
    echo "No core patch in $here/patches; run ./make-patch.sh first." >&2
    exit 1
  fi

  local name="wizzle-nanoclaw-$version"
  local dist="$site/dist/nanoclaw"
  if [ -e "$dist/$name.tar.gz" ]; then
    echo "$name is already built, and a published version never changes; pick a new version." >&2
    exit 1
  fi

  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' EXIT
  mkdir -p "$stage/$name/skills" "$stage/$name/patches" "$dist"
  cp -R "$fork_skill" "$stage/$name/skills/add-wizzle"
  cp -R "$here/skills/add-wizzle-core" "$stage/$name/skills/add-wizzle-core"
  cp "$here"/patches/*.patch "$stage/$name/patches/"
  printf '%s\n' "$version" >"$stage/$name/VERSION"
  find "$stage" -name .DS_Store -delete

  # COPYFILE_DISABLE keeps macOS tar from adding ._ metadata files.
  COPYFILE_DISABLE=1 tar -C "$stage" -czf "$dist/$name.tar.gz" "$name"
  (cd "$dist" && shasum -a 256 "$name.tar.gz" >"$name.tar.gz.sha256")
  printf '%s\n' "$version" >"$dist/latest"
  echo "Built $dist/$name.tar.gz"
}

# The OpenClaw bundle is the plugin's npm pack archive, installed with openclaw plugins install npm-pack:.
build_openclaw() {
  local name="wizzle-openclaw-$version"
  local dist="$site/dist/openclaw"
  if [ -e "$dist/$name.tgz" ]; then
    echo "$name is already built, and a published version never changes; pick a new version." >&2
    exit 1
  fi
  mkdir -p "$dist"
  "$openclaw_dir/pack.sh" "$version" "$dist" >/dev/null
  (cd "$dist" && shasum -a 256 "$name.tgz" >"$name.tgz.sha256")
  printf '%s\n' "$version" >"$dist/latest"
  echo "Built $dist/$name.tgz"
}

if [ "$runtime" = openclaw ]; then build_openclaw; else build_nanoclaw; fi
cp "$here/wizzle.sh" "$site/install.sh"
