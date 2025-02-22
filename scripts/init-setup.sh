#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Ask user for Kubernetes version
read -p "Enter Kubernetes version (e.g., 1.32): " K8S_VERSION

# Update and upgrade system
sudo apt-get update && sudo apt-get upgrade -y

# Disable swap
sudo swapoff -a

# Configure sysctl for Kubernetes networking
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF

# Apply sysctl settings
sudo sysctl --system

# Verify sysctl setting
sysctl net.ipv4.ip_forward

# Load necessary kernel module
sudo modprobe br_netfilter

# Ensure module loads on boot
echo 'br_netfilter' | sudo tee /etc/modules-load.d/br_netfilter.conf

# Install containerd
sudo apt install containerd -y
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Modify containerd config to use SystemdCgroup
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Restart containerd service
sudo systemctl restart containerd

# Update system
sudo apt-get update

# Install necessary packages
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Add Kubernetes repository key
curl -fsSL https://pkgs.k8s.io/core:/stable:/v$K8S_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$K8S_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list

# Update system again
sudo apt-get update

# Install Kubernetes components
sudo apt-get install -y kubelet kubeadm kubectl

# Prevent automatic upgrades of Kubernetes packages
sudo apt-mark hold kubelet kubeadm kubectl

echo "Kubernetes setup complete!"
