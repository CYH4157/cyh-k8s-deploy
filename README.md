# cyh-k8s-deploy


## master node
sudo systemctl stop kubelet

sudo rm -rf /etc/cni/net.d /var/lib/cni /var/log/calico /var/run/calico
sudo mkdir -p /etc/cni/net.d /var/lib/cni
sudo chmod 755 /etc/cni/net.d

sudo mkdir -p /opt/cni/bin
sudo chmod 755 /opt/cni/bin

sudo systemctl restart containerd
sudo systemctl restart kubelet


### debug

kubectl -n kube-system get pods -o wide | grep calico-node


kubectl -n kube-system describe pod calico-node-XXXXX | sed -n '/Init Containers:/,/Events:/p'
kubectl -n kube-system logs calico-node-XXXXX -c install-cni --tail=200 || true

