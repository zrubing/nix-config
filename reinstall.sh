mount /dev/disk/by-label/NIXROOT /mnt
mount -o umask=0077 /dev/disk/by-label/NIXBOOT /mnt/boot

rfkill unblock wlan
ip link set wlp1s0 up

wpa_supplicant -c /mnt/etc/supplicant.conf -B -i wlp1s0

nixos-install
