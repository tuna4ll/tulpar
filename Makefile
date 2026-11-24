ARCH ?= x86_64
BUILD := build-$(ARCH)
IMAGE := $(BUILD)/tulpar.img

QEMUFLAGS_x86_64 ?= -enable-kvm -cpu host -m 4G -M q35 -smp 2 \
	-drive file=$(IMAGE),format=raw \
	-device qemu-xhci -device usb-kbd -device usb-tablet \
	-netdev user,id=net0 -device virtio-net-pci,netdev=net0,disable-legacy=on
# Tunix on arm64: UEFI on QEMU's virt machine, the root on NVMe, ramfb for a screen.
AARCH64_FIRMWARE ?= /usr/share/edk2/aarch64/QEMU_EFI.fd
QEMUFLAGS_aarch64 ?= -M virt -cpu cortex-a72 -m 4G -smp 2 -bios $(AARCH64_FIRMWARE) \
	-drive file=$(IMAGE),if=none,id=disk,format=raw -device nvme,drive=disk,serial=tulpar \
	-device ramfb -device qemu-xhci -device usb-kbd -device usb-tablet \
	-netdev user,id=net0 -device virtio-net-pci,netdev=net0,disable-legacy=on
QEMUFLAGS ?= $(QEMUFLAGS_$(ARCH))

.PHONY: all image iso run clean

all: image

# makeimg.sh refreshes outdated packages itself, so the image is always rebuilt.
image:
	mkdir -p $(BUILD)
	cd $(BUILD) && ../build-support/makeimg.sh

iso:
	mkdir -p $(BUILD)
	cd $(BUILD) && IMAGE_NAME=tulpar.iso ../build-support/makeimg.sh

run:
	@test -f $(IMAGE) || $(MAKE) image
	qemu-system-$(ARCH) $(QEMUFLAGS) -serial stdio

clean:
	rm -f $(IMAGE) $(BUILD)/tulpar.iso
