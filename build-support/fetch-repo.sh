#! /bin/sh
# Fills build-<arch> with the packages tulpar-packs already has, so that jinx
# only builds what changed since they were published.
# Usage: fetch-repo.sh <arch> [build dir]

set -e

repo=tuna4ll/tulpar-packs
arch="$1"
dir="${2:-build-${arch}}"
xbps="$(cd "$(dirname "$0")/.." && pwd)/.jinx-cache/xbps/bin"

mkdir -p "${dir}/pkgs" "${dir}/host-pkgs"
rel=packages; [ "${arch}" = x86_64 ] || rel="packages-${arch}"
gh release download "${rel}" -R ${repo} -D "${dir}/pkgs" --skip-existing -p "*.${arch}.xbps*"
gh release download "host-${arch}" -R ${repo} -D "${dir}/host-pkgs" --skip-existing -p '*.xbps'

# Index them afresh rather than trusting the published index.
XBPS_TARGET_ARCH="${arch}" "${xbps}"/xbps-rindex -a "${dir}"/pkgs/*.xbps
XBPS_TARGET_ARCH=x86_64 "${xbps}"/xbps-rindex -a "${dir}"/host-pkgs/*.xbps
