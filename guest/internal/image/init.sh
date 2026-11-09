#!/bin/busybox sh
# PID 1 for the microvm initramfs. The kernel is started with rdinit=/init.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
export HOME=/root

mkdir -p /proc /sys /dev /dev/pts /dev/shm /tmp /root /var/log /run /etc

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /dev/shm
mount -t tmpfs tmpfs /tmp

load_modules() {
    file=$1
    [ -f "$file" ] || return 0
    while IFS= read -r ko; do
        [ -z "$ko" ] && continue
        [ -f "$ko" ] || continue
        insmod "$ko" || echo "microvm-init: insmod failed: $ko"
    done < "$file"
}

# vsock must be up before the agent listens. NAT is not on that path:
# a slow DHCP client used to delay the first exec.
load_modules /etc/microvm-vsock-modules

hostname microvm >/dev/null 2>&1 || true
ip link set lo up 2>/dev/null || true

if [ ! -x /usr/local/bin/microvm-agent ]; then
    echo "microvm-init: missing /usr/local/bin/microvm-agent"
else
    echo "microvm-init: starting microvm-agent"
    setsid /usr/local/bin/microvm-agent &
fi

(
    load_modules /etc/microvm-net-modules
    # Outbound NAT only. VZNATNetworkDeviceAttachment serves DHCP to the guest.
    for i in /sys/class/net/*; do
        [ -e "$i" ] || continue
        name=${i##*/}
        [ "$name" = "lo" ] && continue
        ip link set "$name" up 2>/dev/null || true
        if [ -x /sbin/udhcpc ] && [ -f /usr/share/udhcpc/default.script ]; then
            udhcpc -i "$name" -t 8 -T 1 -b -q -s /usr/share/udhcpc/default.script || true
        fi
    done
) &

# Reap zombies. The VM stays up until the agent powers it off.
while true; do
    wait || true
    sleep 1
done
