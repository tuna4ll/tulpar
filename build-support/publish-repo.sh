#! /bin/sh
# Signs build-<arch>/pkgs and publishes it to tulpar-packs, together with the
# host packages that build used, so that CI can start from them.
# Usage: publish-repo.sh [arch...]; every build-* directory by default.

set -e

repo=tuna4ll/tulpar-packs
key="${XBPS_PRIVKEY:-${HOME}/.config/tulpar/xbps-signing.pem}"
xbps="$(dirname "$0")/../.jinx-cache/xbps/bin"

[ $# -gt 0 ] || set -- $(ls -d build-*/pkgs | sed 's|^build-||; s|/pkgs$||')

# sync_release <release> <dir> <arch>: uploads what is missing or changed in
# the release and drops the <arch> packages that <dir> no longer has.
sync_release() {
    rel="$1" dir="$2" arch="$3"
    gh release view "${rel}" -R ${repo} >/dev/null 2>&1 ||
        gh release create "${rel}" -R ${repo} --title "${rel}" --notes "Packages for Tulpar."

    have="$(gh release view "${rel}" -R ${repo} --json assets -q '.assets[]|[.name,.digest]|@tsv')"
    upload=""
    for f in "${dir}"/*.xbps "${dir}"/*.xbps.sig2 "${dir}/${arch}-repodata"; do
        [ -f "${f}" ] || continue
        sum="sha256:$(sha256sum "${f}" | cut -d' ' -f1)"
        printf '%s\n' "${have}" | grep -qxF "${f##*/}	${sum}" || upload="${upload} ${f}"
    done
    [ -z "${upload}" ] || gh release upload "${rel}" -R ${repo} --clobber ${upload}

    printf '%s\n' "${have}" | cut -f1 | grep -F ".${arch}.xbps" | while read -r asset; do
        [ -f "${dir}/${asset}" ] || gh release delete-asset "${rel}" "${asset}" -R ${repo} -y
    done
}

for arch in "$@"; do
    pkgs="build-${arch}/pkgs"
    XBPS_TARGET_ARCH="${arch}" "${xbps}"/xbps-rindex --sign --signedby "Tulpar" --privkey "${key}" "${pkgs}"
    XBPS_TARGET_ARCH="${arch}" "${xbps}"/xbps-rindex --sign-pkg --privkey "${key}" "${pkgs}"/*.xbps >/dev/null

    # A release holds at most 1000 files, so each architecture but x86_64 has
    # its own, as base-files tells the systems.
    if [ "${arch}" = x86_64 ]; then
        sync_release packages "${pkgs}" "${arch}"
    else
        sync_release "packages-${arch}" "${pkgs}" "${arch}"

        # Systems from before the split still read the shared release: leave
        # them only base-files there, which moves them to their own.
        bridge="build-${arch}/bridge"
        rm -rf "${bridge}" && mkdir -p "${bridge}"
        base="$(ls "${pkgs}"/base-files-*."${arch}".xbps | sort -V | tail -1)"
        cp "${base}" "${base}.sig2" "${bridge}/"
        XBPS_TARGET_ARCH="${arch}" "${xbps}"/xbps-rindex -a "${bridge}"/*.xbps
        XBPS_TARGET_ARCH="${arch}" "${xbps}"/xbps-rindex --sign --signedby "Tulpar" --privkey "${key}" "${bridge}"
        sync_release packages "${bridge}" "${arch}"
    fi
    # Host tools run on the x86_64 builder but differ per target.
    sync_release "host-${arch}" "build-${arch}/host-pkgs" x86_64
done
