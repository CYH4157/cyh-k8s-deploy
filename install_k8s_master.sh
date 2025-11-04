#!/bin/bash
set -e

MASTER_IP="140.110.160.34"
POD_CIDR="10.244.0.0/16"
CALICO_VERSION="v3.27.2"
MAX_RETRY=6
SLEEP_INTERVAL=15

echo "=== [1/8] Install prerequisites ==="
sudo apt update -y
sudo apt install -y apt-transport-https ca-certificates curl gpg

echo "=== [2/8] Install Kubernetes components ==="
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update -y
sudo apt install -y kubelet kubeadm kubectl
sudo systemctl enable kubelet

echo "=== [3/8] Initialize Kubernetes master ==="
sudo kubeadm init --apiserver-advertise-address=${MASTER_IP} --pod-network-cidr=${POD_CIDR} --upload-certs

echo "=== [4/8] Configure kubectl environment ==="
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "=== [5/8] Deploy Calico (VXLAN mode) ==="
curl -O https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml
kubectl apply -f calico.yaml
sleep 10

echo "=== [6/8] Configure Calico environment variables ==="
kubectl -n kube-system set env daemonset/calico-node CALICO_IPV4POOL_TYPE="vxlan"
kubectl -n kube-system set env daemonset/calico-node CALICO_IPV4POOL_NAT_OUTGOING="true"
kubectl -n kube-system set env daemonset/calico-node CALICO_IPV4POOL_CIDR="${POD_CIDR}"
kubectl -n kube-system set env daemonset/calico-node FELIX_WIREGUARDENABLED="false"
kubectl -n kube-system set env daemonset/calico-node IP_AUTODETECTION_METHOD="can-reach=8.8.8.8"
kubectl -n kube-system set env daemonset/calico-node KUBERNETES_SERVICE_HOST="${MASTER_IP}"
kubectl -n kube-system set env daemonset/calico-node KUBERNETES_SERVICE_PORT="6443"

echo "=== [7/8] Restart Calico and wait for readiness ==="
kubectl -n kube-system delete pods -l k8s-app=calico-node --force --grace-period=0

attempt=1
while [ $attempt -le $MAX_RETRY ]; do
    echo "Checking Calico status (attempt ${attempt}/${MAX_RETRY})..."
    if kubectl get pods -n kube-system | grep -q "calico-node"; then
        notready=$(kubectl get pods -n kube-system | grep calico-node | grep -v Running | wc -l)
        if [ "$notready" -eq 0 ]; then
            echo "All Calico nodes are running."
            break
        fi
    fi
    echo "Waiting ${SLEEP_INTERVAL}s before retry..."
    sleep $SLEEP_INTERVAL
    attempt=$((attempt + 1))
done

if [ "$notready" -ne 0 ]; then
    echo "Warning: Some Calico pods are not ready after ${MAX_RETRY} retries."
    kubectl get pods -n kube-system -o wide | grep calico
    echo "You can run 'kubectl describe pod -n kube-system <pod>' for diagnostics."
else
    echo "Calico network is fully operational."
fi

echo "=== [8/8] Cluster status summary ==="
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide | egrep 'calico|coredns|kube-'

echo ""
echo "Kubernetes master setup completed successfully."
echo "Use the following command on worker nodes to join the cluster:"
echo ""
echo "sudo kubeadm join ${MASTER_IP}:6443 --token <token> --discovery-token-ca-cert-hash <hash>"
