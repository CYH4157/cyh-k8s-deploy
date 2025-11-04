#!/bin/bash
set -e

### === 使用者可自訂區 === ###
K8S_VERSION="v1.31"
POD_CIDR="10.244.0.0/16"
SVC_CIDR="10.96.0.0/12"
PUBLIC_IP="140.110.160.242"      # master 對外 IP
PRIVATE_IP=$(hostname -I | awk '{print $1}')   # 自動偵測本機內部 IP
NODE_NAME=$(hostname)
CALICO_VERSION="v3.27.2"
### ====================== ###

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
sudo sysctl --system

echo "[Step 4] 啟用 kubelet"
sudo systemctl enable kubelet

echo "[Step 5] 安裝 Kubernetes $K8S_VERSION"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update -y
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

### 清理舊叢集 ###
echo "[Cleanup] 檢查是否有舊叢集殘留"
sudo kubeadm reset -f || true
sudo systemctl stop kubelet || true
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet/* /etc/cni /var/lib/cni /root/.kube
sudo netstat -tulpn 2>/dev/null | grep 1025 || true

### 初始化 Master 節點 ###
if [ "$1" == "master" ]; then
    echo "[Master] 初始化 Kubernetes 控制平面"
    sudo kubeadm init \
      --apiserver-advertise-address=${PRIVATE_IP} \
      --apiserver-cert-extra-sans=${PUBLIC_IP},${PRIVATE_IP} \
      --pod-network-cidr=${POD_CIDR} \
      --service-cidr=${SVC_CIDR} \
      --node-name=${NODE_NAME} \
      --ignore-preflight-errors=FileAvailable,Port-10250,Port-10251,Port-10252,Port-10257,Port-10259

    echo "[Master] 設定 kubectl 環境"
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config

    echo "[Master] 安裝 CNI（Calico ${CALICO_VERSION}）"
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml

    ### === CNI 自動修復區段 === ###
    echo "[CNI Check] 檢查 /opt/cni/bin 是否存在 Calico 插件..."
    if [ ! -f /opt/cni/bin/calico ] || [ ! -f /opt/cni/bin/calico-ipam ]; then
        echo "[CNI Fix] 未找到 Calico plugin，嘗試修復..."
        sudo mkdir -p /opt/cni/bin
        # 嘗試從常見路徑複製（支援 containerd 環境）
        sudo cp -r /var/lib/rancher/rke2/data/*/bin/* /opt/cni/bin/ 2>/dev/null || true
        sudo cp -r /usr/lib/cni/* /opt/cni/bin/ 2>/dev/null || true
        sudo systemctl restart containerd
        sudo systemctl restart kubelet
    fi

    echo "[CNI Check] 確認 containerd CNI 設定"
    if ! grep -q 'bin_dir = "/opt/cni/bin"' /etc/containerd/config.toml; then
        sudo sed -i '/\[plugins."io.containerd.grpc.v1.cri".cni\]/,/\[plugins."io.containerd.grpc.v1.cri".registry\]/ s#bin_dir =.*#bin_dir = "/opt/cni/bin"#' /etc/containerd/config.toml || true
        sudo sed -i '/\[plugins."io.containerd.grpc.v1.cri".cni\]/,/\[plugins."io.containerd.grpc.v1.cri".registry\]/ s#conf_dir =.*#conf_dir = "/etc/cni/net.d"#' /etc/containerd/config.toml || true
        sudo systemctl restart containerd
        sudo systemctl restart kubelet
    fi

    echo "[CNI Check] 等待節點變為 Ready..."
    for i in {1..30}; do
        STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
        if [[ "$STATUS" == "Ready" ]]; then
            echo "✅ 節點已就緒！"
            break
        fi
        echo "等待節點就緒中... ($i/30)"
        sleep 10
    done

    echo "[Master] Calico 狀態確認："
    kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
    echo "[Master] 安裝完成！請使用以下命令加入 worker 節點："
    kubeadm token create --print-join-command
fi
