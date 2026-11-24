#!/bin/sh

# Builds a bootable GPT disk image: an EFI system partition with Limine and
# the Tunix kernel, and an ext4 root.
#
# With IMAGE_NAME=*.iso it builds a live ISO instead, for a CD, a DVD or (it
# is a hybrid image) a USB stick: Limine and the kernel in ISO 9660, booted
# by BIOS and UEFI through El Torito or from the stick's partition table, and
# the ext4 root as a partition appended to it. Tunix mounts that root "live":
# it never writes the disc, and what is changed stays in memory.

set -e

script_dir="$(dirname "$0")"
test -z "${script_dir}" && script_dir=.

source_dir="$(cd "${script_dir}"/.. && pwd -P)"
build_dir="$(pwd -P)"

# mkfs.ext4 and sfdisk are in sbin, which not every distro puts in the PATH of users.
PATH="${PATH}:/usr/sbin:/sbin"

# Run a command as root of a user namespace that maps root to the user who
# builds, where the files of that user are root's, as they have to be in the
# image, and with root's usual umask.
as_root() {
    ( umask 022 && exec unshare --user --map-root-user -- "$@" )
}

case "$(basename "${build_dir}")" in
    build-x86_64) ARCH=x86_64 ;;
    build-aarch64) ARCH=aarch64 ;;
    *)
        echo "error: The build directory must be called 'build-<architecture>'." 1>&2
        exit 1
        ;;
esac

IMAGE_SIZE="${IMAGE_SIZE:-4G}"
IMAGE_NAME="${IMAGE_NAME:-tulpar.img}"
case "${IMAGE_NAME}" in
    *.iso)
        live=yes
        # The ISO is a release download, which GitHub keeps under 2 GiB a file;
        # devel can be installed on the running system with xbps-install.
        PKGS_TO_INSTALL="${PKGS_TO_INSTALL-desktop}"
        ;;
    *) live=no ;;
esac
PKGS_TO_INSTALL="${PKGS_TO_INSTALL-desktop devel}"

set -f
as_root rm -rf sysroot

if ! [ -f .jinx-parameters ]; then
    "${source_dir}"/jinx init "${source_dir}" ARCH="${ARCH}"
fi

# update only looks at the packages it is named, so name everything they need.
"${source_dir}"/jinx update -b $("${source_dir}"/jinx closure base $PKGS_TO_INSTALL)
as_root "${source_dir}"/jinx install "sysroot" base $PKGS_TO_INSTALL
set +f

"${source_dir}"/jinx update -b host:limine

# The boot partition: Limine for BIOS and UEFI, its config and the kernel.
rm -rf limine-tmp esp_root
mkdir limine-tmp
( cd limine-tmp && tar -xf "$(ls -1 ../host-pkgs/limine-*.xbps | sort -Vr | head -1)" )
limine_dir=limine-tmp/usr/local/share/limine

mkdir -p esp_root/EFI/BOOT esp_root/boot/limine
case "${ARCH}" in
    x86_64)
        cp "${limine_dir}"/BOOTX64.EFI "${limine_dir}"/BOOTIA32.EFI esp_root/EFI/BOOT/
        cp "${limine_dir}"/limine-bios.sys esp_root/boot/limine/
        cp sysroot/usr/share/tunix/kernel.elf esp_root/boot/
        protocol=limine
        kernel=kernel.elf
        ;;
    aarch64)
        # Tunix boots on arm64 as an Image, with the Linux protocol.
        cp "${limine_dir}"/BOOTAA64.EFI esp_root/EFI/BOOT/
        cp sysroot/usr/share/tunix/Image esp_root/boot/
        protocol=linux
        kernel=Image
        ;;
esac

if [ "${live}" = yes ]; then
    root="root=LABEL=tulpar-live live"
else
    root="root=LABEL=tulpar-root"
fi

cat <<CONF >esp_root/boot/limine/limine.conf
timeout: 3

/Tulpar
    protocol: ${protocol}
    path: boot():/boot/${kernel}
    cmdline: ${root} init=/sbin/init

/Tulpar - emergency shell
    protocol: ${protocol}
    path: boot():/boot/${kernel}
    cmdline: ${root} init=/usr/libexec/tulpar-rescue
CONF

if [ "${live}" = yes ]; then
    # El Torito boots BIOS from Limine's CD stage, and UEFI from its FAT image.
    [ "${ARCH}" = x86_64 ] && cp "${limine_dir}"/limine-bios-cd.bin esp_root/boot/limine/
    [ "${ARCH}" = x86_64 ] && bios_boot="-b boot/limine/limine-bios-cd.bin -no-emul-boot
        -boot-load-size 4 -boot-info-table"

    # The root, sized to what it holds; it is only read, so it has no journal
    # and no blocks kept for root.
    rm -f rootfs.ext4 "${IMAGE_NAME}"
    trap 'rm -f rootfs.ext4 "${IMAGE_NAME}"' EXIT HUP INT TERM
    used_kib=$(as_root du -sk sysroot | cut -f1)
    files=$(as_root find sysroot | wc -l)
    as_root mkfs.ext4 -q -L tulpar-live -O ^has_journal -m 0 -N $((files + files / 4 + 4096)) \
        -d sysroot rootfs.ext4 "$((used_kib + used_kib / 10 + 65536))k"

    # An MBR, which Limine's BIOS stages need, with three partitions: the ISO
    # 9660 file system itself, the FAT image as the ESP (also UEFI's El Torito
    # image), and the root.
    xorriso -as mkisofs -R -J -V TULPAR -partition_offset 16 ${bios_boot:-} \
        -append_partition 2 0xef "${limine_dir}"/limine-uefi-cd.bin \
        -append_partition 3 0x83 rootfs.ext4 \
        -eltorito-alt-boot -e --interval:appended_partition_2:all:: -no-emul-boot \
        -o "${IMAGE_NAME}" esp_root
    [ "${ARCH}" = x86_64 ] && limine-tmp/usr/local/bin/limine bios-install "${IMAGE_NAME}"

    trap - EXIT HUP INT TERM
    rm -rf rootfs.ext4 limine-tmp esp_root
    exit 0
fi

# Disk layout: GPT with a 1 MiB BIOS boot partition for Limine's BIOS stage
# (unused on aarch64, kept so the root is partition 3 everywhere), a 64 MiB ESP
# and the rest ext4.
bios_start=2048
bios_sectors=2048
esp_start=$((bios_start + bios_sectors))
esp_sectors=131072
root_start=$((esp_start + esp_sectors))

# Delete a half-written image rather than leave behind something that looks
# like a finished one.
rm -f "${IMAGE_NAME}"
trap 'rm -f "${IMAGE_NAME}"' EXIT HUP INT TERM

fallocate -l "${IMAGE_SIZE}" "${IMAGE_NAME}"
sfdisk --quiet "${IMAGE_NAME}" <<PARTS
label: gpt
start=${bios_start}, size=${bios_sectors}, type=21686148-6449-6E6F-744E-656564454649, name=BIOS
start=${esp_start}, size=${esp_sectors}, type=uefi, name=ESP
start=${root_start}, type=linux, name=tulpar-root
PARTS

# sfdisk aligns the end of the root partition, so ask it for the real size.
root_sectors=$(partx -g -o SECTORS -n 3 "${IMAGE_NAME}" | tr -d ' ')
as_root mkfs.ext4 -q -L tulpar-root -d sysroot \
    -E offset=$((root_start * 512)) "${IMAGE_NAME}" "$((root_sectors / 2))k"

esp="${IMAGE_NAME}@@$((esp_start * 512))"
mformat -i "${esp}" -F -T ${esp_sectors} -v TULPAR-ESP ::
mcopy -s -i "${esp}" esp_root/EFI esp_root/boot ::/

if [ "${ARCH}" = x86_64 ]; then
    limine-tmp/usr/local/bin/limine bios-install "${IMAGE_NAME}" 1
fi

trap - EXIT HUP INT TERM
rm -rf limine-tmp esp_root
sync
