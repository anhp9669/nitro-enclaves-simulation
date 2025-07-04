#!/bin/sh
# Minimal init script that restarts the enclave app on crash

echo "Starting minimal enclave init system..."

# Create necessary directories
mkdir -p /proc /sys /dev /tmp /run

# Mount essential filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t tmpfs none /tmp
mount -t devtmpfs none /dev

# Set up basic networking
ip link set lo up

# Start the enclave app with restart loop
echo "Starting enclave app..."
while true; do
  echo "Launching enclave binary..."
  /home/alpine/enclave
  echo "Enclave app crashed or exited, restarting in 1 second..."
  sleep 1
done 