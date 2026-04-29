#!/usr/bin/env bash
set -e

echo "Installing build dependencies..."

sudo apt update

sudo apt install -y \
 autoconf \
 automake \
 libtool \
 libtool-bin \
 pkg-config \
 build-essential \
 git \
 wget \
 curl \
 bc \
 bison \
 flex \
 libssl-dev \
 libelf-dev \
 libblkid-dev \
 libudev-dev \
 libaio-dev \
 libattr1-dev \
 libtirpc-dev \
 libcurl4-openssl-dev \
 libffi-dev \
 libpam0g-dev \
 zlib1g-dev \
 uuid-dev \
 python3 \
 python3-dev \
 python3-cffi \
 python3-setuptools \
 gawk \
 linux-headers-generic \
 dwarves \
 debootstrap \
 squashfs-tools \
 xorriso \
 grub-pc-bin \
 grub-efi-amd64-bin \
 mtools \
 dosfstools \
 rsync \
 gdisk \
 dracut \
 cpio \
 xz-utils \
 kmod

echo "Done."