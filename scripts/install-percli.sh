#!/usr/bin/env bash
# Installs percli, the Perses CLI, on Linux or macOS from the official GitHub release, after verifying the
# archive against the release's checksums file. Installs the percli binary and the release's plugins-archive/
# folder, which offline `percli migrate --plugin.path` needs to convert Grafana dashboards.
#
#   scripts/install-percli.sh                      # version 0.54.0 into ~/.local/bin and ~/.local/share/perses
#   PERCLI_VERSION=0.54.0 PREFIX=/usr/local/bin PLUGINS_DIR=/usr/local/share/perses scripts/install-percli.sh
#
# 0.54.0 is the Perses version the Cluster Observability Operator 1.5 builds on (rhobs/observability-operator,
# branch release-1.5, go.mod: github.com/perses/perses v0.54.0). Match percli to the cluster's Perses.
set -euo pipefail

VERSION="${PERCLI_VERSION:-0.54.0}"
PREFIX="${PREFIX:-${HOME}/.local/bin}"
PLUGINS_DIR="${PLUGINS_DIR:-${HOME}/.local/share/perses}"
BASE="https://github.com/perses/perses/releases/download/v${VERSION}"

case "$(uname -s)" in
  Linux)  os=linux ;;
  Darwin) os=darwin ;;
  *) echo "unsupported OS: $(uname -s) (Linux and macOS only)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "unsupported CPU: $(uname -m) (amd64 and arm64 only)" >&2; exit 1 ;;
esac

# sha256sum on Linux, shasum on macOS (no sha256sum there by default)
if command -v sha256sum >/dev/null 2>&1; then sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else echo "need sha256sum or shasum to verify the download" >&2; exit 1; fi

archive="perses_${VERSION}_${os}_${arch}.tar.gz"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

echo "downloading ${archive} and perses_${VERSION}_checksums.txt from ${BASE}"
curl -fsSL -o "${work}/${archive}" "${BASE}/${archive}"
curl -fsSL -o "${work}/checksums.txt" "${BASE}/perses_${VERSION}_checksums.txt"

# exact file name: the checksums file also lists an .sbom.spdx.json per archive
expected="$(awk -v f="${archive}" '$2 == f { print $1 }' "${work}/checksums.txt")"
actual="$(sha256 "${work}/${archive}")"
[[ -n "${expected}" ]] || { echo "${archive} is not in the release's checksums file" >&2; exit 1; }
[[ "${expected}" == "${actual}" ]] || { echo "checksum mismatch for ${archive}: expected ${expected}, got ${actual}" >&2; exit 1; }
echo "checksum OK: ${actual}"

tar -xzf "${work}/${archive}" -C "${work}" percli plugins-archive
mkdir -p "${PREFIX}" "${PLUGINS_DIR}"
install -m 0755 "${work}/percli" "${PREFIX}/percli"
# replaced as a whole, so a plugin dropped from a newer release does not linger
rm -rf "${PLUGINS_DIR}/plugins-archive"
cp -R "${work}/plugins-archive" "${PLUGINS_DIR}/plugins-archive"
echo "installed ${PREFIX}/percli"
echo "installed ${PLUGINS_DIR}/plugins-archive ($(ls "${PLUGINS_DIR}/plugins-archive" | wc -l | tr -d ' ') plugins): pass it to percli migrate --plugin.path"
"${PREFIX}/percli" version
case ":${PATH}:" in *":${PREFIX}:"*) ;; *) echo "note: ${PREFIX} is not on PATH; add it, or call ${PREFIX}/percli" ;; esac
