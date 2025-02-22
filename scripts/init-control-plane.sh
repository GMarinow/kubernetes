#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Ask user for control plane endpoint and node name
read -p "Enter Control Plane Endpoint (e.g., 192.168.2.230): " CONTROL_PLANE_ENDPOINT
read -p "Enter Node Name (should be the computer name): " NODE_NAME
read -p "Enter MetalLB IP Range (e.g., 192.168.1.100-192.168.150 *should be outside ot DHCP range*): " METALLB_IP_RANGE

# Initialize Kubernetes master node
sudo kubeadm init --control-plane-endpoint $CONTROL_PLANE_ENDPOINT --node-name $NODE_NAME --pod-network-cidr=10.244.0.0/16

# Set up kubeconfig for the current user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Apply Flannel CNI for networking
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Deploy MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml

# Wait for MetalLB system to be ready
kubectl wait --namespace metallb-system --for=condition=Available deployment --all --timeout=120s

# Create MetalLB config file
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
kubectl apply -f metallb-config.yaml

# Generate and display the join command for worker nodes
JOIN_COMMAND=$(kubeadm token create --print-join-command)
echo "Run the following command on worker nodes to join the cluster:"
echo "$JOIN_COMMAND"

echo "Master node setup complete!"
