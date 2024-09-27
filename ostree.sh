#!/bin/bash
set -euo pipefail

# Dumps details about the instance running the CI job.

CPUS=$(nproc)
MEM=$(free -m | grep -oP '\d+' | head -n 1)
DISK=$(df --output=size -h / | sed '1d;s/[^0-9]//g')
HOSTNAME=$(uname -n)
USER=$(whoami)
ARCH=$(uname -m)
KERNEL=$(uname -r)

# Get OS data.
source /etc/os-release

echo -e "\033[0;36m"
cat << EOF
------------------------------------------------------------------------------
CI MACHINE SPECS
------------------------------------------------------------------------------
     Hostname: ${HOSTNAME}
         User: ${USER}
         CPUs: ${CPUS}
          RAM: ${MEM} MB
         DISK: ${DISK} GB
         ARCH: ${ARCH}
       KERNEL: ${KERNEL}
           OS: ${ID}-${VERSION_ID}
------------------------------------------------------------------------------
EOF
echo -e "\033[0m"

# Install packages
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
dnf install -y osbuild-composer \
               composer-cli \
               ansible \
               jq \
               httpd \
               qemu-kvm \
               libvirt-daemon-kvm \
               virt-install \
               wget \
               firewalld
rpm -qa | grep -i osbuild

# Prepare osbuild-composer repository file
if [ -d /etc/osbuild-composer/repositories  ]; then
    # Clean previous runs repositories and cache
    rm -fr /etc/osbuild-composer/repositories/*
    rm -rf /var/cache/osbuild-composer/rpmmd/*
else
    mkdir -p /etc/osbuild-composer/repositories
fi

# Set ostree ref. This need to be 'rhel/8/*/edge', because it's hardoded at the code
OSTREE_REF="rhel/8/${ARCH}/edge"

# Set os-variant and boot location used by virt-install.
case "${ID}-${VERSION_ID}" in
    "rhel-8.4")
        IMAGE_TYPE=rhel-edge-commit
        OS_VARIANT="rhel8-unknown"
        BOOT_LOCATION="http://download-node-02.eng.bos.redhat.com/rhel-8/rel-eng/RHEL-8/latest-RHEL-8.4.0/compose/BaseOS/${ARCH}/os/"
        cp -fv files/rhel-8-4-0.json /etc/osbuild-composer/repositories/rhel-8-beta.json
        ln -sfv /etc/osbuild-composer/repositories/rhel-8-beta.json /etc/osbuild-composer/repositories/rhel-8.json
        ;;
    "centos-8")
        IMAGE_TYPE=rhel-edge-commit
        OS_VARIANT="rhel8-unknown"
        BOOT_LOCATION="http://mirror.centos.org/centos/8-stream/BaseOS/${ARCH}/os/"
        # CentOS Stream Workaround
        cp -fv /etc/os-release files/
        cp -fv /etc/redhat-release files/
        cp -fv files/rhel-8-4-0-os-release /etc/os-release
        cp -fv files/rhel-8-4-0-rh-release /etc/redhat-release
        cp -fv /usr/share/osbuild-composer/repositories/centos-stream-8.json /etc/osbuild-composer/repositories/
        ln -sfv /etc/osbuild-composer/repositories/centos-stream-8.json /etc/osbuild-composer/repositories/rhel-8.json
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1
        ;;
esac

# Start image builder service
if systemctl is-active osbuild-composer > /dev/null ; then
    systemctl restart osbuild-composer
else
    systemctl enable --now osbuild-composer.socket
fi

# Start firewalld
systemctl enable --now firewalld

# Basic verification
composer-cli status show
composer-cli sources list
for SOURCE in $(composer-cli sources list); do
    composer-cli sources info "$SOURCE"
done

sleep 5

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Start libvirtd and test it.
greenprint "🚀 Starting libvirt daemon"
systemctl start libvirtd
virsh list --all > /dev/null

# Set a customized dnsmasq configuration for libvirt so we always get the
# same address on bootup.
tee /tmp/integration.xml > /dev/null << EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>integration</name>
  <uuid>1c8fe98c-b53a-4ca4-bbdb-deb0f26b3579</uuid>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='integration' zone='trusted' stp='on' delay='0'/>
  <mac address='52:54:00:36:46:ef'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.100.2' end='192.168.100.254'/>
      <host mac='34:49:22:B0:83:30' name='vm' ip='192.168.100.50'/>
    </dhcp>
  </ip>
</network>
EOF
if virsh net-info integration > /dev/null 2>&1; then
    virsh net-destroy integration
    virsh net-undefine integration
fi

virsh net-define /tmp/integration.xml
virsh net-start integration

# Allow anyone in the wheel group to talk to libvirt.
greenprint "🚪 Allowing users in wheel group to talk to libvirt"
WHEEL_GROUP=wheel
if [[ $ID == rhel ]]; then
    WHEEL_GROUP=adm
fi
tee /etc/polkit-1/rules.d/50-libvirt.rules > /dev/null << EOF
polkit.addRule(function(action, subject) {
    if (action.id == "org.libvirt.unix.manage" &&
        subject.isInGroup("${WHEEL_GROUP}")) {
            return polkit.Result.YES;
    }
});
EOF

# Set up variables.
TEST_UUID=$(uuidgen)
IMAGE_KEY="osbuild-composer-ostree-test-${TEST_UUID}"
GUEST_ADDRESS=192.168.100.50

# Set up temporary files.
TEMPDIR=$(mktemp -d)
BLUEPRINT_FILE=${TEMPDIR}/blueprint.toml
KS_FILE=${TEMPDIR}/ks.cfg
COMPOSE_START=${TEMPDIR}/compose-start-${IMAGE_KEY}.json
COMPOSE_INFO=${TEMPDIR}/compose-info-${IMAGE_KEY}.json
HTTPD_PATH="/var/www/html"

# Start httpd to serve ostree repo and HTTP boot server
greenprint "🚀 Starting httpd daemon"
systemctl start httpd

# SSH setup.
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key
chmod 600 "$SSH_KEY"

# Get the compose log.
get_compose_log () {
    COMPOSE_ID=$1
    LOG_FILE=osbuild-${ID}-${VERSION_ID}-${COMPOSE_ID}.log

    # Download the logs.
    composer-cli compose log "$COMPOSE_ID" | tee "$LOG_FILE" > /dev/null
}

# Get the compose metadata.
get_compose_metadata () {
    COMPOSE_ID=$1
    METADATA_FILE=osbuild-${ID}-${VERSION_ID}-${COMPOSE_ID}.json

    # Download the metadata.
    composer-cli compose metadata "$COMPOSE_ID" > /dev/null

    # Find the tarball and extract it.
    TARBALL=$(basename "$(find . -maxdepth 1 -type f -name "*-metadata.tar")")
    tar -xf "$TARBALL" -C "${TEMPDIR}"
    rm -f "$TARBALL"

    # Move the JSON file into place.
    cat "${TEMPDIR}"/"${COMPOSE_ID}".json | jq -M '.' | tee "$METADATA_FILE" > /dev/null
}

# Build ostree image.
build_image() {
    blueprint_file=$1
    blueprint_name=$2

    # Prepare the blueprint for the compose.
    greenprint "📋 Preparing blueprint"
    composer-cli blueprints push "$blueprint_file"
    composer-cli blueprints depsolve "$blueprint_name"

    # Get worker unit file so we can watch the journal.
    WORKER_UNIT=$(systemctl list-units | grep -o -E "osbuild.*worker.*\.service")
    journalctl -af -n 1 -u "${WORKER_UNIT}" &
    WORKER_JOURNAL_PID=$!

    # Start the compose.
    greenprint "🚀 Starting compose"
    if [[ $blueprint_name == upgrade ]]; then
        # composer-cli in Fedora 32 has a different start-ostree arguments
        # see https://github.com/weldr/lorax/pull/1051
        composer-cli --json compose start-ostree --ref "$OSTREE_REF" --parent "$COMMIT_HASH" "$blueprint_name" $IMAGE_TYPE | tee "$COMPOSE_START"
    else
        composer-cli --json compose start "$blueprint_name" $IMAGE_TYPE | tee "$COMPOSE_START"
    fi
    COMPOSE_ID=$(jq -r '.build_id' "$COMPOSE_START")

    # Wait for the compose to finish.
    greenprint "⏱ Waiting for compose to finish: ${COMPOSE_ID}"
    while true; do
        composer-cli --json compose info "${COMPOSE_ID}" | tee "$COMPOSE_INFO" > /dev/null
        COMPOSE_STATUS=$(jq -r '.queue_status' "$COMPOSE_INFO")

        # Is the compose finished?
        if [[ $COMPOSE_STATUS != RUNNING ]] && [[ $COMPOSE_STATUS != WAITING ]]; then
            echo ; greenprint "🚀 Finished compose"
            break
        fi
        echo -n "."

        # Wait 30 seconds and try again.
        sleep 5
    done

    # Capture the compose logs from osbuild.
    greenprint "💬 Getting compose log and metadata"
    get_compose_log "$COMPOSE_ID"
    get_compose_metadata "$COMPOSE_ID"

    # Did the compose finish with success?
    if [[ $COMPOSE_STATUS != FINISHED ]]; then
        echo "Something went wrong with the compose. 😢"
        exit 1
    fi

    # Stop watching the worker journal.
    kill ${WORKER_JOURNAL_PID}
}

# Wait for the ssh server up to be.
wait_for_ssh_up () {
    SSH_STATUS=$(ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@"${1}" '/bin/bash -c "echo -n READY"')
    if [[ $SSH_STATUS == READY ]]; then
        echo 1
    else
        echo 0
    fi
}

# Clean up our mess.
clean_up () {
    greenprint "🧼 Cleaning up"
    virsh destroy "${IMAGE_KEY}"
    virsh undefine "${IMAGE_KEY}" --nvram
    # Remove "remote" repo.
    rm -rf "${HTTPD_PATH}"/{repo,compose.json}
    # Remomve tmp dir.
    rm -rf "$TEMPDIR"
    # Stop httpd
    systemctl disable httpd --now
    # Restore the *-release files
    if [[ "$ID" == "centos" ]]; then
        cp -fv files/os-release /etc/
        cp -vf files/redhat-release /etc/
    fi
}

# Test result checking
check_result () {
    greenprint "Checking for test result"
    if [[ $RESULTS == 1 ]]; then
	greenprint "Cheking OS version"
	ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@"${GUEST_ADDRESS}" '/bin/bash -c "cat /etc/redhat-release"'
        greenprint "💚 Success"
    else
        greenprint "❌ Failed"
        clean_up
        exit 1
    fi
}

##################################################
##
## ostree image/commit installation
##
##################################################

# Write a blueprint for ostree image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "ostree"
description = "A base ostree image"
version = "0.0.1"
modules = []
groups = []
[[packages]]
name = "python36"
version = "*"

[customizations.services]
enabled = [ "ostree-remount" ]
EOF

# Build installation image.
build_image "$BLUEPRINT_FILE" ostree

# Download the image and extract tar into web server root folder.
greenprint "📥 Downloading and extracting the image"
composer-cli compose image "${COMPOSE_ID}" > /dev/null
IMAGE_FILENAME="${COMPOSE_ID}-commit.tar"
tar -xf "${IMAGE_FILENAME}" -C ${HTTPD_PATH}
rm -f "$IMAGE_FILENAME"

# Clean compose and blueprints.
greenprint "Clean up osbuild-composer"
composer-cli compose delete "${COMPOSE_ID}" > /dev/null
composer-cli blueprints delete ostree > /dev/null

# Get ostree commit value.
greenprint "Get ostree image commit value"
COMMIT_HASH=$(jq -r '."ostree-commit"' < ${HTTPD_PATH}/compose.json)

# Ensure SELinux is happy with our new images.
greenprint "👿 Running restorecon on image directory"
restorecon -Rv /var/lib/libvirt/images/

# Create qcow2 file for virt install.
greenprint "Create qcow2 file for virt install"
LIBVIRT_IMAGE_PATH=/var/lib/libvirt/images/${IMAGE_KEY}.qcow2
qemu-img create -f qcow2 "${LIBVIRT_IMAGE_PATH}" 20G

# Write kickstart file for ostree image installation.
greenprint "Generate kickstart file"
tee "$KS_FILE" > /dev/null << STOPHERE
text
lang en_US.UTF-8
keyboard us
timezone --utc Etc/UTC
selinux --enforcing
rootpw --lock --iscrypted locked
user --name=admin --groups=wheel --iscrypted --password=\$6\$1LgwKw9aOoAi/Zy9\$Pn3ErY1E8/yEanJ98evqKEW.DZp24HTuqXPJl6GYCm8uuobAmwxLv7rGCvTRZhxtcYdmC0.XnYRSR9Sh6de3p0
sshkey --username=admin "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzxo5dEcS+LDK/OFAfHo6740EyoDM8aYaCkBala0FnWfMMTOq7PQe04ahB0eFLS3IlQtK5bpgzxBdFGVqF6uT5z4hhaPjQec0G3+BD5Pxo6V+SxShKZo+ZNGU3HVrF9p2V7QH0YFQj5B8F6AicA3fYh2BVUFECTPuMpy5A52ufWu0r4xOFmbU7SIhRQRAQz2u4yjXqBsrpYptAvyzzoN4gjUhNnwOHSPsvFpWoBFkWmqn0ytgHg3Vv9DlHW+45P02QH1UFedXR2MqLnwRI30qqtaOkVS+9rE/dhnR+XPpHHG+hv2TgMDAuQ3IK7Ab5m/yCbN73cxFifH4LST0vVG3Jx45xn+GTeHHhfkAfBSCtya6191jixbqyovpRunCBKexI5cfRPtWOitM3m7Mq26r7LpobMM+oOLUm4p0KKNIthWcmK9tYwXWSuGGfUQ+Y8gt7E0G06ZGbCPHOrxJ8lYQqXsif04piONPA/c9Hq43O99KPNGShONCS9oPFdOLRT3U= ostree-image-test"
bootloader --timeout=1 --append="net.ifnames=0 modprobe.blacklist=vc4"
network --bootproto=dhcp --device=link --activate --onboot=on
zerombr
clearpart --all --initlabel --disklabel=msdos
autopart --nohome --noswap --type=plain
ostreesetup --nogpg --osname=${IMAGE_TYPE} --remote=${IMAGE_TYPE} --url=http://192.168.100.1/repo/ --ref=${OSTREE_REF}
poweroff
%post --log=/var/log/anaconda/post-install.log --erroronfail
# no password for user admin
echo -e 'admin\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers
# Remove any persistent NIC rules generated by udev
rm -vf /etc/udev/rules.d/*persistent-net*.rules
# And ensure that we will do DHCP on eth0 on startup
cat > /etc/sysconfig/network-scripts/ifcfg-eth0 << EOF
DEVICE="eth0"
BOOTPROTO="dhcp"
ONBOOT="yes"
TYPE="Ethernet"
PERSISTENT_DHCLIENT="yes"
EOF
echo "Packages within this iot or edge image:"
echo "-----------------------------------------------------------------------"
rpm -qa | sort
echo "-----------------------------------------------------------------------"
# Note that running rpm recreates the rpm db files which aren't needed/wanted
rm -f /var/lib/rpm/__db*
echo "Zeroing out empty space."
# This forces the filesystem to reclaim space from deleted files
dd bs=1M if=/dev/zero of=/var/tmp/zeros || :
rm -f /var/tmp/zeros
echo "(Don't worry -- that out-of-space error was expected.)"
%end
STOPHERE

# Install ostree image via anaconda.
greenprint "Install ostree image via anaconda"
virt-install  --name="${IMAGE_KEY}"\
                   --disk path="${LIBVIRT_IMAGE_PATH}",format=qcow2 \
                   --ram 3072 \
                   --vcpus 2 \
                   --network network=integration,mac=34:49:22:B0:83:30 \
                   --os-type linux \
                   --os-variant "${OS_VARIANT}" \
                   --location "${BOOT_LOCATION}" \
                   --initrd-inject="${KS_FILE}" \
                   --extra-args="ks=file:/ks.cfg console=ttyS0,115200" \
                   --nographics \
                   --wait=-1 \
                   --noreboot

# Start VM.
greenprint "Start VM"
virsh start "${IMAGE_KEY}"

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for LOOP_COUNTER in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check image installation result
check_result

# Final success clean up
clean_up

greenprint "Here is the resulted VM: $LIBVIRT_IMAGE_PATH"

exit 0
