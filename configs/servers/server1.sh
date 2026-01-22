#!/bin/bash

# Server1 configuration script
echo "Configuring server1..."

# Configure network interfaces
ip addr add 10.1.1.10/24 dev eth1 2>/dev/null || true

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# Start nginx for testing (may already be running in newer multitool images)
nginx 2>/dev/null || true

echo "Server1 configuration completed"