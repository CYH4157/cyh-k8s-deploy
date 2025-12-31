#!/bin/bash
set -euo pipefail

### === 使用者可自訂區 === ###
K8S_VERSION="v1.31"
POD_CIDR="192.168.0.0/16"
SVC_CIDR="10.96.0.0/12"
CALICO_VERSION="v3.27.2"
### ====================== ###

PRIVATE_IP=$(hostname -I | awk '{print $1}')
PUBLIC_IP=$(curl -fsS ifconfig.me || curl -fsS https://ipinfo.io/ip || true)
NODE_NAME=$(hostname)

echo "=== [INFO] Private IP: ${PRIVATE_IP}"
echo "=== [INFO] Public  IP: ${PUBLIC_IP:-N/A}"

echo "[Step 1] 更新套件 & 安裝必備工具"
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release net-tools \
  conntrack socat ebtables ethtool ipset

echo "[Step 2] 安裝 & 設定 containerd"
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd

echo "[Step 3] 關閉 swap & sysctl"
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system >/dev/null

echo "[Step 4] 安裝 Kubernetes ${K8S_VERSION}"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

echo "[Cleanup] 清理舊叢集（只做 reset + 目錄清理，不亂砍 CNI 之後再裝）"
sudo kubeadm reset -f || true
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet/* /root/.kube
sudo rm -rf /etc/cni/net.d /var/lib/cni
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete cali0 2>/dev/null || true
sudo iptables -F || true
sudo iptables -t nat -F || true
sudo iptables -t mangle -F || true

echo "[Step 5] kubeadm init"
INIT_ARGS=(
  --apiserver-advertise-address="${PRIVATE_IP}"
  --pod-network-cidr="${POD_CIDR}"
  --service-cidr="${SVC_CIDR}"
  --node-name="${NODE_NAME}"
)

# 有 public ip 才加 SAN / control-plane-endpoint
if [[ -n "${PUBLIC_IP:-}" ]]; then
  INIT_ARGS+=(
    --apiserver-cert-extra-sans="${PUBLIC_IP},${PRIVATE_IP}"
    --control-plane-endpoint="${PUBLIC_IP}:6443"
  )
fi

sudo kubeadm init "${INIT_ARGS[@]}"

echo "[Step 6] 設定 kubectl"
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo "[Step 7] 安裝 Calico ${CALICO_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

echo "[Step 8] 等待節點 Ready"
kubectl get pods -A -o wide || true
for i in {1..30}; do
  if kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -q '^Ready$'; then
    echo "✅ Master Ready"
    break
  fi
  echo "等待中 ($i/30)..."
  sleep 5
done

echo "[完成] Master 安裝完成 ✅"
echo "Join command："
kubeadm token create --print-join-command
