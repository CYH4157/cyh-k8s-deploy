#!/bin/bash
set -e

echo "=== [1/6] Install prerequisites ==="
sudo apt update -y
sudo apt install -y apt-transport-https ca-certificates curl gpg

echo "=== [2/6] Install containerd ==="
sudo apt install -y containerd
sudo systemctl enable containerd
sudo systemctl restart containerd

echo "=== [3/6] Install Kubernetes components ==="
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update -y
sudo apt install -y kubelet kubeadm kubectl cri-tools
sudo systemctl enable kubelet

echo "=== [4/6] Enable IPv4 forwarding ==="
sudo tee -a /etc/sysctl.conf <<EOF
net.ipv4.ip_forward=1
EOF
sudo sysctl -p

echo "=== [5/6] Join the Kubernetes cluster ==="
echo "Please input your kubeadm join command:"
echo "kubeadm join command: " 


echo "=== [6/6] Post-join verification ==="
echo "Waiting for kubelet registration..."
sleep 10
sudo systemctl status kubelet --no-pager || true

echo ""
echo "Worker node setup complete. Verify on master using:"
echo "kubectl get nodes -o wide"
