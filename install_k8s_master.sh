#!/bin/bash
set -e

### === 使用者可自訂區 === ###
K8S_VERSION="v1.31"
POD_CIDR="10.244.0.0/16"
SVC_CIDR="10.96.0.0/12"
CALICO_VERSION="v3.27.2"
### ====================== ###

# 自動偵測 IP
PRIVATE_IP=$(hostname -I | awk '{print $1}')
PUBLIC_IP=$(curl -s ifconfig.me || curl -s https://ipinfo.io/ip)
NODE_NAME=$(hostname)

echo "=== [INFO] 偵測到 Private IP: ${PRIVATE_IP}"
echo "=== [INFO] 偵測到 Public IP: ${PUBLIC_IP}"

echo "[Step 1] 更新系統套件"
sudo apt update -y
sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release net-tools

echo "[Step 2] 安裝 Containerd"
sudo apt install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "[Step 3] 關閉 Swap 與設定 sysctl"
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system 2>/dev/null

echo "[Step 4] 安裝 Kubernetes $K8S_VERSION"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update -y
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "[Step 5] 啟用 kubelet"
sudo systemctl enable kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet

### 清理舊叢集 ###
echo "[Cleanup] 清理舊叢集環境"
sudo kubeadm reset -f || true
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet/* /etc/cni /var/lib/cni /root/.kube
sudo ip link delete cni0 || true
sudo ip link delete flannel.1 || true
sudo ip link delete cali0 || true

echo "[Step 6] 初始化 Master 節點"
sudo kubeadm init \
  --apiserver-advertise-address=${PRIVATE_IP} \
  --apiserver-cert-extra-sans=${PUBLIC_IP},${PRIVATE_IP} \
  --control-plane-endpoint=${PUBLIC_IP}:6443 \
  --pod-network-cidr=${POD_CIDR} \
  --service-cidr=${SVC_CIDR} \
  --node-name=${NODE_NAME} \
  --ignore-preflight-errors=FileAvailable,Port-10250,Port-10251,Port-10252,Port-10257,Port-10259

echo "[Step 7] 設定 kubectl 環境"
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "[Step 8] 安裝 Calico ${CALICO_VERSION}"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml

echo "[Step 9] 修正 kube-apiserver 設定（確保外部 IP 可通）"
sudo sed -i "/--advertise-address/c\    - --advertise-address=${PRIVATE_IP}" /etc/kubernetes/manifests/kube-apiserver.yaml
sudo sed -i "/--bind-address/c\    - --bind-address=0.0.0.0" /etc/kubernetes/manifests/kube-apiserver.yaml
if ! grep -q "${PUBLIC_IP}" /etc/kubernetes/manifests/kube-apiserver.yaml; then
  sudo sed -i "/--service-account-key-file/a\    - --external-hostname=${PUBLIC_IP}" /etc/kubernetes/manifests/kube-apiserver.yaml
fi

echo "[Step 10] 重新啟動 kubelet"
sudo systemctl restart kubelet

echo "[Step 11] 等待節點就緒"
for i in {1..30}; do
  STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
  if [[ "$STATUS" == "Ready" ]]; then
    echo "✅ Master node 已就緒！"
    break
  fi
  echo "等待中 ($i/30)..."
  sleep 10
done

echo "[完成] Master 安裝完成 ✅"
echo "請用以下指令加入 worker 節點："
kubeadm token create --print-join-command
