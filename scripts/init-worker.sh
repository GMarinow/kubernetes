#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Ask user for Kubernetes version
read -p "Enter Kubernetes version (e.g., 1.32): " K8S_VERSION

# Ask user for Master Node IP
read -p "Enter Master Node IP: " MASTER_IP

# Update and upgrade system
echo "Updating and upgrading the system..."
sudo apt-get update && sudo apt-get upgrade -y

# Disable swap
echo "Disabling swap..."
sudo swapoff -a
sudo sed -i '/swap/ s/^/#/' /etc/fstab

# Configure sysctl for Kubernetes networking
echo "Configuring sysctl for Kubernetes networking..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system
sysctl net.ipv4.ip_forward

# Load necessary kernel module
echo "Loading kernel module br_netfilter..."
sudo modprobe br_netfilter

echo "Ensuring module loads on boot..."
echo 'br_netfilter' | sudo tee /etc/modules-load.d/br_netfilter.conf

# Install containerd
echo "Installing containerd..."
sudo apt install containerd -y
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Modify containerd config to use SystemdCgroup
echo "Configuring containerd to use SystemdCgroup..."
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Restart containerd service
echo "Restarting containerd service..."
sudo systemctl restart containerd

# Update system
echo "Updating system packages..."
sudo apt-get update

# Install necessary packages
echo "Installing necessary packages..."
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Add Kubernetes repository key
echo "Adding Kubernetes repository key..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v$K8S_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes repository
echo "Adding Kubernetes repository..."
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$K8S_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list

# Update system again
echo "Updating package lists again..."
sudo apt-get update

# Install Kubernetes components
echo "Installing Kubernetes components..."
sudo apt-get install -y kubelet kubeadm kubectl

# Prevent automatic upgrades of Kubernetes packages
echo "Marking Kubernetes packages to prevent auto-updates..."
sudo apt-mark hold kubelet kubeadm kubectl

echo "Kubernetes setup complete!"

# Wait for the control-plane to be ready
while true; do
    echo "Checking if the control-plane is ready..."
    # Check if all control-plane nodes are ready
    STATUS=$(ssh -o StrictHostKeyChecking=no $MASTER_IP "kubectl get nodes --selector=node-role.kubernetes.io/control-plane --no-headers | awk '{print \$2}'")
    
    # Check if there is any "NotReady" status
    if ! echo "$STATUS" | grep -q "NotReady"; then
        echo "All control-plane nodes are ready. Fetching join command..."
        JOIN_COMMAND=$(ssh -o StrictHostKeyChecking=no $MASTER_IP "sudo kubeadm token create --print-join-command")
        echo "Executing join command on this worker node..."
        sudo $JOIN_COMMAND
        echo "Worker node successfully joined the cluster!"
        break
    else
        echo "Some control-plane nodes are not ready yet. Retrying in 1 minute..."
        sleep 60
    fi
done
