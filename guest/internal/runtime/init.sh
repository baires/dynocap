#!/bin/busybox sh
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/work/home
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /tmp
mkdir -p /run/lock
mount -t ext4 /dev/vdb /work || exec sh
mkdir -p /work/project /work/home
ip link set lo up
load_modules() {
 while IFS= read -r ko; do [ -z "$ko" ] || insmod "$ko"; done < "$1"
}
load_modules /etc/microvm-vsock-modules
setsid /usr/local/bin/microvm-agent &
(
 load_modules /etc/microvm-net-modules
 for i in /sys/class/net/*; do
  name=${i##*/}; [ "$name" = lo ] && continue
  ip link set "$name" up
  udhcpc -i "$name" -t 8 -T 1 -b -q -s /usr/share/udhcpc/default.script
 done
) &
while true; do wait || true; sleep 1; done
