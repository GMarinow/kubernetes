#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Ask user for Kubernetes version
echo "[INFO] Asking user for Kubernetes version..."
read -p "Enter Kubernetes version (e.g., 1.32): " K8S_VERSION

# Ask user for control plane endpoint and node name
echo "[INFO] Asking user for Control Plane Endpoint and Node Name..."
read -p "Enter Control Plane Endpoint (e.g., 192.168.2.230): " CONTROL_PLANE_ENDPOINT
read -p "Enter Node Name (should be the computer name): " NODE_NAME
read -p "Enter MetalLB IP Range (e.g., 192.168.1.100-192.168.150 *should be outside of DHCP range*): " METALLB_IP_RANGE

# Update and upgrade system
echo "[INFO] Updating and upgrading the system..."
sudo apt-get update && sudo apt-get upgrade -y

# Disable swap
echo "[INFO] Disabling swap..."
sudo swapoff -a
echo "[INFO] Commenting out swap in /etc/fstab..."
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Configure sysctl for Kubernetes networking
echo "[INFO] Configuring sysctl for Kubernetes networking..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF

# Apply sysctl settings
echo "[INFO] Applying sysctl settings..."
sudo sysctl --system

# Verify sysctl setting
echo "[INFO] Verifying sysctl setting..."
sysctl net.ipv4.ip_forward

# Load necessary kernel module
echo "[INFO] Loading br_netfilter kernel module..."
sudo modprobe br_netfilter

# Ensure module loads on boot
echo "[INFO] Ensuring br_netfilter loads on boot..."
echo 'br_netfilter' | sudo tee /etc/modules-load.d/br_netfilter.conf

# Install containerd
echo "[INFO] Installing containerd..."
sudo apt install containerd -y
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Modify containerd config to use SystemdCgroup
echo "[INFO] Modifying containerd config to use SystemdCgroup..."
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Restart containerd service
echo "[INFO] Restarting containerd service..."
sudo systemctl restart containerd

# Update system
echo "[INFO] Updating system again..."
sudo apt-get update

# Install necessary packages
echo "[INFO] Installing necessary packages..."
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Add Kubernetes repository key
echo "[INFO] Adding Kubernetes repository key..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v$K8S_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes repository
echo "[INFO] Adding Kubernetes repository..."
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$K8S_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list

# Update system again
echo "[INFO] Updating system again..."
sudo apt-get update

# Install Kubernetes components
echo "[INFO] Installing Kubernetes components..."
sudo apt-get install -y kubelet kubeadm kubectl

# Prevent automatic upgrades of Kubernetes packages
echo "[INFO] Holding Kubernetes packages..."
sudo apt-mark hold kubelet kubeadm kubectl

echo "[INFO] Kubernetes setup complete!"

# Initialize Kubernetes master node
echo "[INFO] Initializing Kubernetes master node..."
sudo kubeadm init --control-plane-endpoint $CONTROL_PLANE_ENDPOINT --node-name $NODE_NAME --pod-network-cidr=10.244.0.0/16

# Set up kubeconfig for the current user
echo "[INFO] Setting up kubeconfig for the current user..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Apply Flannel CNI for networking
echo "[INFO] Applying Flannel CNI for networking..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Deploy MetalLB
echo "[INFO] Deploying MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml

# Wait for MetalLB system to be ready
echo "[INFO] Waiting for MetalLB to be ready..."
kubectl wait --namespace metallb-system --for=condition=Available deployment --all --timeout=120s

# Create MetalLB config file
echo "[INFO] Creating MetalLB configuration file..."
cat <<EOF | tee metallb-config.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb-pool
  namespace: metallb-system
spec:
  addresses:
  - $METALLB_IP_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: metallb-advertisement
  namespace: metallb-system
EOF

# Apply MetalLB configuration
echo "[INFO] Applying MetalLB configuration..."
kubectl apply -f metallb-config.yaml

# Generate and display the join command for worker nodes
echo "[INFO] Generating join command for worker nodes..."
JOIN_COMMAND=$(sudo kubeadm token create --print-join-command)
echo "[INFO] Run the following command on worker nodes to join the cluster:"
echo "$JOIN_COMMAND"

echo "[INFO] Master node setup complete!"

# Ask user if they want to deploy Cloudflare Tunnel
read -p "Do you want to deploy Cloudflare Tunnel (y/n)? " DEPLOY_CLOUDFLARED

if [[ "$DEPLOY_CLOUDFLARED" == "y" || "$DEPLOY_CLOUDFLARED" == "Y" ]]; then
  # Prompt user for the Cloudflare Tunnel token
  read -p "Enter your Cloudflare Tunnel token: " CLOUDFLARED_TOKEN

  # Check if the token is empty
  if [ -z "$CLOUDFLARED_TOKEN" ]; then
    echo "Error: Token cannot be empty"
    exit 1
  fi

  # Create the Kubernetes namespace for Cloudflare if it doesn't exist
  kubectl get namespace cloudflared > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "Namespace 'cloudflared' does not exist. Creating it now..."
    kubectl create namespace cloudflared
  fi

  # Create the Kubernetes deployment file with the provided token
  cat <<EOF > cloudflared-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflared
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:latest
          args:
            - tunnel
            - --no-autoupdate
            - run
            - --token
            - "$CLOUDFLARED_TOKEN"
EOF

  # Deploy Cloudflare Tunnel
  echo "[INFO] Deploying Cloudflare Tunnel to the Kubernetes cluster..."
  kubectl apply -f cloudflared-deployment.yaml -n cloudflared

  # Check if the deployment was successful
  if [ $? -eq 0 ]; then
    echo "[INFO] Cloudflare Tunnel deployment was successful."
  else
    echo "[ERROR] Deployment failed. Please check the logs for errors."
    exit 1
  fi
fi
