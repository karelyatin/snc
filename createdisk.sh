#!/bin/bash

set -exuo pipefail

export LC_ALL=C
export LANG=C

source tools.sh
source createdisk-library.sh

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_ecdsa_crc"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_ecdsa_crc"
# If the user set OKD_VERSION in the environment, then use it to override OPENSHIFT_VERSION, set BASE_OS
# Unless, those variables are explicitly set as well.
OKD_VERSION=${OKD_VERSION:-none}
if [[ ${OKD_VERSION} != "none" ]]
then
    OPENSHIFT_VERSION=${OKD_VERSION}
    BASE_OS=fedora-coreos
fi
BASE_OS=${BASE_OS:-rhcos}

# CRC_VM_NAME: short VM name to use in crc_libvirt.sh
# BASE_DOMAIN: domain used for the cluster
# VM_PREFIX: full VM name with the random string generated by openshift-installer
CRC_VM_NAME=${CRC_VM_NAME:-crc}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}

if [[ $# -ne 1 ]]; then
   echo "You need to provide the running cluster directory to copy kubeconfig"
   exit 1
fi

VM_PREFIX=$(get_vm_prefix ${CRC_VM_NAME})

# Remove unused images from container storage
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo crictl rmi --prune'

# Get the IP of the VM
INTERNAL_IP=$(${DIG} +short api.${CRC_VM_NAME}.${BASE_DOMAIN})

# Disable kubelet service
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo systemctl disable kubelet

# Stop the kubelet service so it will not reprovision the pods
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo systemctl stop kubelet

# Enable the podman.socket service for API V2
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo systemctl enable podman.socket

# Remove audit logs
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo find /var/log/ -iname "*.log" -exec rm -f {} \;'

if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ]; then
    prepare_hyperV "$1"
fi

# Add gvisor-tap-vsock and crc-dnsmasq services
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} 'sudo bash -x -s' <<EOF
  podman create --name=gvisor-tap-vsock --privileged --net=host -v /etc/resolv.conf:/etc/resolv.conf -it quay.io/crcont/gvisor-tap-vsock:3231aba53905468c22e394493a0debc1a6cc6392
  podman generate systemd --restart-policy=no gvisor-tap-vsock > /etc/systemd/system/gvisor-tap-vsock.service
  touch /var/srv/dnsmasq.conf
  podman create --ip 10.88.0.8 --name crc-dnsmasq -v /var/srv/dnsmasq.conf:/etc/dnsmasq.conf -p 53:53/udp --privileged quay.io/crcont/dnsmasq:latest
  podman generate systemd --restart-policy=no crc-dnsmasq > /etc/systemd/system/crc-dnsmasq.service
  systemctl daemon-reload
  systemctl enable gvisor-tap-vsock.service
EOF

# Add dummy crio-wipe service to instance
cat crio-wipe.service | ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} "sudo tee -a /etc/systemd/system/crio-wipe.service"

# Preload routes controller
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo crictl pull quay.io/crcont/routes-controller:latest'

# Change the ownership of authorized_keys file
# https://bugzilla.redhat.com/show_bug.cgi?id=1956739
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo chown core.core ~/.ssh/authorized_keys'

# Shutdown and Start the VM after installing the hyperV daemon packages.
# This is required to get the latest ostree layer which have those installed packages.
shutdown_vm ${VM_PREFIX}
start_vm ${VM_PREFIX}

# Only used for macOS bundle generation
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    # Get the rhcos ostree Hash ID
    ostree_hash=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- "cat /proc/cmdline | grep -oP \"(?<=${BASE_OS}-).*(?=/vmlinuz)\"")

    # Get the rhcos kernel release
    kernel_release=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'uname -r')

    # Get the kernel command line arguments
    kernel_cmd_line=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'cat /proc/cmdline')

    # SCP the vmlinuz/initramfs from VM to Host in provided folder.
    ${SCP} -r core@api.${CRC_VM_NAME}.${BASE_DOMAIN}:/boot/ostree/${BASE_OS}-${ostree_hash}/* $1
fi

# Add internalIP as node IP for kubelet systemd unit file
# More details at https://bugzilla.redhat.com/show_bug.cgi?id=1872632
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} 'sudo bash -x -s' <<EOF
    echo '[Service]' > /etc/systemd/system/kubelet.service.d/80-nodeip.conf
    echo 'Environment=KUBELET_NODE_IP="${INTERNAL_IP}"' >> /etc/systemd/system/kubelet.service.d/80-nodeip.conf
EOF

# Workaround for https://bugzilla.redhat.com/show_bug.cgi?id=1729603
# TODO: Should be removed once latest podman available or the fix is backported.
# Issue found in podman version 1.4.2-stable2 (podman-1.4.2-5.el8.x86_64)
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo rm -fr /etc/cni/net.d/100-crio-bridge.conf'
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo rm -fr /etc/cni/net.d/200-loopback.conf'

podman_version=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'rpm -q --qf %{version} podman')

# Remove the journal logs.
# Note: With `sudo journalctl --rotate --vacuum-time=1s`, it doesn't
# remove all the journal logs so separate commands are used here.
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo journalctl --rotate'
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- 'sudo journalctl --vacuum-time=1s'

# Shutdown the VM
shutdown_vm ${VM_PREFIX}

# Download podman clients
download_podman $podman_version

# libvirt image generation
get_dest_dir
destDirSuffix="${DEST_DIR}"

libvirtDestDir="crc_libvirt_${destDirSuffix}_${yq_ARCH}"
mkdir "$libvirtDestDir"

create_qemu_image "$libvirtDestDir"
copy_additional_files "$1" "$libvirtDestDir"
create_tarball "$libvirtDestDir"

# HyperKit image generation
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    hyperkitDestDir="crc_hyperkit_${destDirSuffix}_${yq_ARCH}"
    generate_hyperkit_bundle "$libvirtDestDir" "$hyperkitDestDir" "$1" "$kernel_release" "$kernel_cmd_line"
fi

# vfkit image generation
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    vfkitDestDir="crc_vfkit_${destDirSuffix}_${yq_ARCH}"
    generate_vfkit_bundle "$libvirtDestDir" "$vfkitDestDir" "$1" "$kernel_release" "$kernel_cmd_line"
fi

# HyperV image generation
#
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ]; then
    hypervDestDir="crc_hyperv_${destDirSuffix}_${yq_ARCH}"
    generate_hyperv_bundle "$libvirtDestDir" "$hypervDestDir"
fi

# Cleanup up vmlinux/initramfs files
rm -fr "$1/vmlinuz*" "$1/initramfs*"
