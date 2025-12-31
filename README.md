# cyh-k8s-deploy


## master node

'''
sudo systemctl stop kubelet
'''


'''
sudo rm -rf /etc/cni/net.d /var/lib/cni /var/log/calico /var/run/calico
sudo mkdir -p /etc/cni/net.d /var/lib/cni
sudo chmod 755 /etc/cni/net.d
'''

'''
sudo mkdir -p /opt/cni/bin
sudo chmod 755 /opt/cni/bin
'''


'''
sudo systemctl restart containerd
sudo systemctl restart kubelet
'''

## master node clean calico node
'''
kubectl -n kube-system delete pod -l k8s-app=calico-node --field-selector spec.nodeName=worker1
'''


### debug

kubectl -n kube-system get pods -o wide | grep calico-node


kubectl -n kube-system describe pod calico-node-XXXXX | sed -n '/Init Containers:/,/Events:/p'
kubectl -n kube-system logs calico-node-XXXXX -c install-cni --tail=200 || true

watch -n 2 'kubectl get nodes -o wide; echo; kubectl get pods -n kube-system -o wide | egrep "calico-node|coredns|kube-proxy"'
