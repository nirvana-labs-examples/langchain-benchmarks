#!/bin/bash
# Mount the single 80k-IOPS gp3 data volume at /opt and host all benchmark
# I/O on it (fio + benchmark dirs + Docker data-root), matching the
# single-volume layout of the other platforms.
set -x
exec > /var/log/datadisk-setup.log 2>&1

# Wait for the 256G data volume (root is 100G, so size disambiguates)
for i in $(seq 1 60); do
  DISK=$(lsblk -bdno NAME,SIZE | awk '$2==274877906944 {print "/dev/"$1}' | head -1)
  [ -n "$DISK" ] && break
  sleep 5
done

if [ -z "$DISK" ]; then
  echo "FATAL: 256G data disk not found" > /datadisk-setup-failed
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y xfsprogs

mkfs.xfs -f "$DISK"
mkdir -p /opt
echo "$DISK /opt xfs defaults,nofail 0 2" >> /etc/fstab
mount /opt

# Docker isn't installed yet (Ansible installs it); pre-seed its data-root
mkdir -p /etc/docker /opt/docker-data
cat > /etc/docker/daemon.json << 'EOF'
{ "data-root": "/opt/docker-data" }
EOF

touch /opt/.disk-ready
