#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

read -p "Enter the Kubernetes version (e.g., v1.32): " KUBE_VERSION
read -p "Enter the control plane endpoint: " CONTROL_PLANE_ENDPOINT
read -p "Enter the node name: " NODE_NAME


log() {
    echo "[INFO] $1"
}

error_exit() {
    echo "[ERROR] $1" >&2
    exit 1
}

log "Updating and upgrading system packages..."
sudo apt-get update && sudo apt-get upgrade -y || error_exit "Failed to update system packages."

log "Disabling swap..."
sudo swapoff -a || error_exit "Failed to disable swap."
sudo sed -i '/swap/s/^/#/' /etc/fstab || error_exit "Failed to update /etc/fstab."

log "Configuring sysctl for Kubernetes..."
echo -e "net.bridge.bridge-nf-call-ip6tables = 1\nnet.bridge.bridge-nf-call-iptables = 1\nnet.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/kubernetes.conf

log "Loading kernel modules for containerd..."
echo -e "overlay\nbr_netfilter" | sudo tee /etc/modules-load.d/containerd.conf

sudo modprobe overlay
sudo modprobe br_netfilter

log "Applying sysctl settings..."
sudo sysctl --system || error_exit "Failed to apply sysctl settings."

log "Installing containerd..."
sudo apt install containerd -y || error_exit "Failed to install containerd."
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || error_exit "Failed to configure containerd."
sudo systemctl restart containerd || error_exit "Failed to restart containerd."

log "Installing Kubernetes dependencies..."
sudo apt-get install -y apt-transport-https ca-certificates curl gpg || error_exit "Failed to install dependencies."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg || error_exit "Failed to add Kubernetes GPG key."
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBE_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list

log "Installing Kubernetes components..."
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl || error_exit "Failed to install Kubernetes components."
sudo apt-mark hold kubelet kubeadm kubectl

log "Initializing Kubernetes cluster..."
sudo kubeadm init --control-plane-endpoint "$CONTROL_PLANE_ENDPOINT":6443 --node-name "$NODE_NAME" --pod-network-cidr=10.244.0.0/16 || error_exit "Failed to initialize Kubernetes cluster."

log "Setting up kubectl for the current user..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config || error_exit "Failed to copy Kubernetes config."
sudo chown $(id -u):$(id -g) $HOME/.kube/config || error_exit "Failed to change ownership of Kubernetes config."

log "Deploying Flannel network plugin..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml || error_exit "Failed to apply Flannel network configuration."

log "Kubernetes setup completed successfully."
