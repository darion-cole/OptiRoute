# Troubleshooting (lessons from building this)

### Router won't boot: `EXT4-fs error ... invalid block bitmap`, "remounting read-only"
The root filesystem was resized while OpenWrt was running from it (online `resize2fs`, or the loop-device trick). Reinstall and resize **offline from a live USB** with `tools/flash-and-resize.sh`.

### OpenWrt only shows ~15–100 MB free on a big disk
Normal. The image doesn't grow itself. Use `tools/flash-and-resize.sh`. After a firmware upgrade the filesystem may shrink back. The partition stays large, so just run `resize2fs` on it **from the live USB**.

### `ls /sys/class/net` shows only `lo` (no network cards)
The custom image is missing NIC drivers, usually because the Firmware Selector's default package list was replaced instead of added to. Rebuild, append your extra packages to the end, or use the stock image and `apk add` drivers afterwards.

### `NIC Link is Down` / `cat /sys/class/net/eth0/carrier` = 0
Cable or port. Make sure you're in the built-in port (not a USB adapter without a driver), check the link lights, and try another cable or router port.

### `parted: Partition doesn't exist`
Give parted the **disk**, not a partition: `parted /dev/nvme0n1 resizepart 2 100%`, not `/dev/nvme0n1p2`.

### `dd: can't open '/dev/zero/'`
Trailing slash. Use `/dev/zero`.

### SSH: `REMOTE HOST IDENTIFICATION HAS CHANGED`
Expected after a reinstall at the same IP. Run `ssh-keygen -R <ip>`, then reconnect.

### SSH to old enterprise gear: `no matching MAC found. Their offer: hmac-sha1`
```
ssh -o MACs=hmac-sha1 -o KexAlgorithms=+diffie-hellman-group14-sha1 -o HostKeyAlgorithms=+ssh-rsa admin@<ip>
```

### Windows `scp`: `unknown option -- 0`
It's a capital letter **O** (`scp -O`), not a zero.

### Don't click "Upgrade" on the Software page / don't run `apk upgrade`
Mass-upgrading packages on OpenWrt can break the system. Use **System → Attended Sysupgrade** (or `owut`) to move to a new release. Your `/etc/qosmate.d`, `/etc/geomate.d` and `/etc/lowlatency.sh` are listed in `/etc/sysupgrade.conf`, but the qosmate and geomate *scripts* must be reinstalled afterwards. Re-run `install.sh`, which keeps existing settings.

### DNS stopped working after install
AdGuard's wizard isn't finished. Finish it at `http://<LAN_IP>:3000`, or run `sh tools/adguard-rollback.sh`.

### Terminal page in LuCI is blank
If you reach LuCI over https, the browser blocks the http terminal frame. Use `http://<LAN_IP>`. If you restored a config from another router, reset ttyd:
```sh
printf "config ttyd\n\toption interface '@lan'\n\toption command '/bin/login'\n" > /etc/config/ttyd
/etc/init.d/ttyd enable; /etc/init.d/ttyd restart
```

### Restoring settings from your old OpenWrt router
Don't restore the full backup. It overwrites `network`, and the old port names won't exist. Extract it and copy only what you need:
```sh
mkdir /tmp/old && tar -xzf backup.tar.gz -C /tmp/old
cp /tmp/old/etc/config/dhcp /tmp/old/etc/config/firewall /tmp/old/etc/config/system /etc/config/
```
Skip `network`, `wireless`, and hardware-specific files (`ubootenv`, `ubihealthd`). Check that DHCP reservations and qosmate/geomate rules point at addresses that still exist, and remove "inbound" qosmate rules, which never match.

### Open NAT still shows Moderate/Strict
Check your WAN address: `ifstatus wan | grep '"address"'`.
- `10.x`, `172.16–31.x`, `192.168.x`: your modem is also routing (double NAT). Put it in bridge mode.
- `100.64–100.127.x`: carrier-grade NAT. No router setting can fix it, so ask your ISP for a public IP.
- Public address: make sure your gaming PC's IP is in the UPnP allow list, then fully restart the game.
