#!/bin/bash
# Assemble 5x gp3 (16k IOPS each) into RAID-0 and host all benchmark I/O on it:
# mount at /opt (fio + benchmark dirs) and point Docker data-root there too.
set -x
exec > /var/log/raid-setup.log 2>&1

# Wait for all 5 x 64G data volumes to attach (root is 100G, so size disambiguates)
for i in $(seq 1 60); do
  DISKS=$(lsblk -bdno NAME,SIZE | awk '$2==68719476736 {print "/dev/"$1}')
  N=$(echo "$DISKS" | grep -c nvme)
  [ "$N" -eq 5 ] && break
  sleep 5
done

if [ "$N" -ne 5 ]; then
  echo "FATAL: expected 5 data disks, found $N" > /raid-setup-failed
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y mdadm xfsprogs

mdadm --create /dev/md0 --level=0 --raid-devices=5 --chunk=64 --force --run $DISKS
mkfs.xfs -f /dev/md0

mkdir -p /opt
echo "/dev/md0 /opt xfs defaults,nofail 0 2" >> /etc/fstab
mount /opt

mdadm --detail --scan >> /etc/mdadm/mdadm.conf
update-initramfs -u

# Docker isn't installed yet (Ansible installs it); pre-seed its data-root onto the array
mkdir -p /etc/docker /opt/docker-data
cat > /etc/docker/daemon.json << 'EOF'
{ "data-root": "/opt/docker-data" }
EOF

touch /opt/.raid-ready
