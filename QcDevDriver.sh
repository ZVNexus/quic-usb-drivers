#!/bin/bash

# Copyright (c) 2024, Qualcomm Innovation Center, Inc. All rights reserved.
# SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause

set -e
set -u

source /etc/os-release

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEST_QUIC_PATH="/opt/QUIC"
DEST_INS_DIAG_PATH="${DEST_QUIC_PATH}/USB/diag"
DEST_INS_SERIAL_PATH="${DEST_QUIC_PATH}/USB/serial"
DEST_INS_RMNET_PATH="${DEST_QUIC_PATH}/USB/rmnet"

DRIVER_NAME="quic-usb-drivers"
DRIVER_VERSION="1.0.4.25"
DRIVER_MODULES=(
    "QdssDiag"
    "GobiNet"
)

#DRIVER_MODULES+=("GobiSerial")

install_dependencies() {
    if [ "${ID}" == "rhel" ]; then
        rhel_version=$(rpm -E %{rhel})
        sudo subscription-manager repos --enable codeready-builder-for-rhel-${rhel_version}-$(arch)-rpms
        sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_version}.noarch.rpm
    fi

    if [ "${ID}" == "debian" ] || [ "${ID}" == "ubuntu" ]; then
        sudo apt-get install -y dkms keyutils mokutil
    elif [ "${ID}" == "fedora" ] || [ "${ID}" == "rhel" ]; then
        sudo dnf install -y dkms keyutils mokutil
    else
        echo "${PRETTY_NAME} is not supported by the Qualcomm USB Driver."
        exit 1
    fi
}

secure_boot_enabled() {
    if sudo mokutil --sb-state | grep --silent 'SecureBoot enabled'; then
        echo '****************************************************************'
        echo "WARNING: Secure Boot is enabled!"
        echo '         When Secure Boot is enabled, driver modules must be'
        echo '         signed with a valid private key to be loaded by the'
        echo '         kernel.'
        echo '****************************************************************'
        echo ''
        return 0
    fi
    return 1
}

enroll_secure_boot_key() {
    if [ "${ID}" == "debian" ] || [ "${ID}" == "fedora" ] || [ "${ID}" == "rhel" ]; then
        SECURE_BOOT_KEY="/var/lib/dkms/mok.pub"
        SECURE_BOOT_KEY_PRIV="/var/lib/dkms/mok.key"

        if [ ! -f "${SECURE_BOOT_KEY}" ]; then
            echo "DKMS signing key missing, generating..."
            sudo openssl req -new -x509 -nodes -days 36500 -subj "/CN=DKMS module signing key" \
                -newkey rsa:2048 -keyout "${SECURE_BOOT_KEY_PRIV}" \
                -outform DER -out "${SECURE_BOOT_KEY}" > /dev/null 2>&1
        fi
    elif [ "${ID}" == "ubuntu" ]; then
        SECURE_BOOT_KEY="/var/lib/shim-signed/mok/MOK.der"
        sudo update-secureboot-policy --new-key
    fi

    if sudo mokutil --test-key "${SECURE_BOOT_KEY}" | grep --silent 'already enrolled'; then
        echo "Signing key ${SECURE_BOOT_KEY} is already enrolled."
        return 0
    else
        echo "Signing key ${SECURE_BOOT_KEY} is not enrolled."
        echo "****************************************************************"
        echo "WARNING: You must manually enroll the key using the following"
        echo "command: sudo mokutil --import ${SECURE_BOOT_KEY}"
        echo "After enrolling the key, a reboot is required to finalize the"
        echo "enrollment."
        echo ""
        echo "Please refer to dkms_signing.txt for instructions."
        echo "****************************************************************"

        return 1
    fi
}

uninstall_module_blacklist() {
    sudo rm -f /etc/modprobe.d/qcom-usb-blacklist.conf
}

install_module_blacklist() {
    sudo tee /etc/modprobe.d/qcom-usb-blacklist.conf >/dev/null <<EOF
blacklist option
blacklist qcserial
blacklist qmi_wwan
blacklist usb_wwan
EOF
}

uninstall_udev_rules() {
    sudo rm -f /etc/udev/rules.d/qti_usb_device.rules \
        /etc/udev/rules.d/80-gobinet-usbdevice.rules

    sudo udevadm control --reload-rules
    sudo systemctl restart systemd-udevd.service
}

install_udev_rules() {
    sudo tee /etc/udev/rules.d/qti_usb_device.rules >/dev/null <<EOF
SUBSYSTEMS=="tty", PROGRAM="${DEST_INS_SERIAL_PATH}/qtidev.pl ${DEST_INS_SERIAL_PATH}/qtiname.inf %k", SYMLINK+="%c", MODE="0666"
SUBSYSTEMS=="GobiQMI", MODE="0666"
SUBSYSTEMS=="GobiUSB", MODE="0666"
SUBSYSTEMS=="GobiPorts", MODE="0666"
EOF

    sudo tee /etc/udev/rules.d/80-gobinet-usbdevice.rules >/dev/null <<EOF
SUBSYSTEMS=="usb", ATTRS{idVendor}=="05c6", NAME="usb%n"
EOF

    sudo udevadm control --reload-rules
    sudo systemctl restart systemd-udevd.service
}

uninstall_kernel_module_options() {
    sudo rm -rf \
        /etc/modprobe.d/QdssDiag.conf \
        /etc/modprobe.d/GobiNet.conf \
        /etc/modprobe.d/GobiSerial.conf
}

install_kernel_module_options() {
    sudo mkdir -p ${DEST_INS_DIAG_PATH}
    sudo mkdir -p ${DEST_INS_RMNET_PATH}
    sudo mkdir -p ${DEST_INS_SERIAL_PATH}

    sudo cp -r ${SCRIPT_DIR}/QdssDiag/qdbusb.inf ${DEST_INS_DIAG_PATH}
    sudo cp -r ${SCRIPT_DIR}/QdssDiag/qtiser.inf ${DEST_INS_DIAG_PATH}
    sudo cp -r ${SCRIPT_DIR}/GobiSerial/qtimdm.inf ${DEST_INS_DIAG_PATH}
    sudo cp -r ${SCRIPT_DIR}/GobiSerial/qtiname.inf ${DEST_INS_SERIAL_PATH}
    sudo cp -r ${SCRIPT_DIR}/rmnet/qtiwwan.inf ${DEST_INS_RMNET_PATH}

    sudo tee /etc/modprobe.d/QdssDiag.conf >/dev/null <<EOF
options QdssDiag gQdssInfFilePath=${DEST_INS_DIAG_PATH}/qdbusb.inf gDiagInfFilePath=${DEST_INS_DIAG_PATH}/qtiser.inf debug_g=1
EOF

    sudo tee /etc/modprobe.d/GobiNet.conf >/dev/null <<EOF
options GobiNet gQTIRmnetInfFilePath=${DEST_INS_RMNET_PATH}/qtiwwan.inf debug_g=1 debug_aggr=0
EOF

    sudo tee /etc/modprobe.d/GobiSerial.conf >/dev/null <<EOF
options GobiSerial gQTIModemInfFilePath=${DEST_INS_DIAG_PATH}/qtimdm.inf debug=0
EOF
}

uninstall_kernel_modules() {
    for module in "${DRIVER_MODULES[@]}"; do
        if lsmod | grep -q "^$module"; then
            sudo rmmod $module
        fi
    done
    if sudo dkms status | grep -q "${DRIVER_NAME}/${DRIVER_VERSION}"; then
        sudo dkms remove ${DRIVER_NAME}/${DRIVER_VERSION} --all
    fi
    sudo rm -rf \
        /etc/modules-load.d/qcom-usb.conf \
        /usr/src/${DRIVER_NAME}-${DRIVER_VERSION}
}

install_kernel_modules() {
    uninstall_kernel_modules

    sudo mkdir -p /usr/src/${DRIVER_NAME}-${DRIVER_VERSION}
    sudo cp -r ${SCRIPT_DIR}/* /usr/src/${DRIVER_NAME}-${DRIVER_VERSION}
    sudo dkms add -m ${DRIVER_NAME} -v ${DRIVER_VERSION}
    sudo dkms build -m ${DRIVER_NAME} -v ${DRIVER_VERSION}
    sudo dkms install -m ${DRIVER_NAME} -v ${DRIVER_VERSION}

    sudo tee /etc/modules-load.d/qcom-usb.conf >/dev/null <<EOF
qtiDevInf
QdssDiag
GobiNet
#GobiSerial
EOF

    for module in "${DRIVER_MODULES[@]}"; do
        sudo modprobe $module
    done
}

if [ "$#" -ne 1 ]; then
    echo "Usage: $(basename "$0") <install | uninstall>"
    exit 1
fi

case "$1" in
install)
    install_dependencies
    if secure_boot_enabled; then
        enroll_secure_boot_key
    fi

    install_module_blacklist
    install_udev_rules
    install_kernel_module_options
    install_kernel_modules
    ;;
uninstall)
    uninstall_module_blacklist
    uninstall_udev_rules
    uninstall_kernel_module_options
    uninstall_kernel_modules

    # Wipe out anything left at ${DEST_QUIC_PATH}.
    sudo rm -rf ${DEST_QUIC_PATH}
    ;;
*)
    echo "Usage: $(basename "$0") <install | uninstall>"
    exit 1
    ;;
esac
