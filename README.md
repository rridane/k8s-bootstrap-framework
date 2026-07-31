# k8s-bootstrap-framework

An Ansible framework I built to bootstrap Kubernetes clusters, either with kubeadm
or with RKE2, without ending up with one giant unreadable playbook.

The idea is boring on purpose. Bringing up a cluster is always the same sequence:
prepare the machines, deal with the corporate proxy, set the DNS, install the
container runtime, install the kube packages, then bring up the control plane and
join the workers. So instead of a monolith, this is a catalogue of small,
independent steps. Each step is one Ansible role, it is switched on by a flag in
the inventory, and you reach it by a tag. A small Go runner plays one tag at a
time, and it always shows you a plan before it touches anything.

## The three verbs

Every step is named `verb:target`.

`prepare:*` sets up the host — time, proxy, sysctls, swap, and so on. Each one has
a matching `clean:*` if you want to undo it.

`configure:*` writes a config or a manifest onto the node without starting
anything. For RKE2 that is where the Cilium and kube-vip manifests are generated.

`bootstrap:*` is the step that actually brings up or joins the cluster.

So in practice you run things like `prepare:proxy`, then `configure:rke2_cilium`,
then `bootstrap:rke2_server`.

## The timeline

The steps live under `catalog/`, numbered in the order you would run them:

    00  base machine     time, netplan
    10  proxy            corporate proxy (system env + cntlm for NTLM)
    20  dns              /etc/hosts
    30  load balancer    haproxy + keepalived, when there is no external LB
    40  runtime          containerd
    50  k8s prepare      kube packages, network sysctls, swap, nfs, cli tools
    60  masters          bring up the control plane (kubeadm or RKE2)
    70  workers          join the workers

Everything from 00 to 50 is shared. Only the 60 and 70 steps differ depending on
whether you are doing kubeadm or RKE2.

## The RKE2 path

RKE2 is the path I have pushed the furthest. It runs Cilium in kube-proxy-free
mode (eBPF replaces kube-proxy entirely), and it uses kube-vip to carry the API
VIP instead of an external load balancer. Application traffic gets its own VIP
through Cilium's L2 load balancer, so there are two virtual IPs and no hardware LB
in front.

The order matters: all the manifests are generated first, then the first server
comes up and applies them on its own, then the other control-plane nodes and the
workers join through the VIP.

## Using it

    # the roles, from Ansible Galaxy
    ansible-galaxy collection install -r requirements.yml -p collections

    # the runner
    go build -o cluster ./tools/cluster

    # copy the reference inventory and adapt it to your machines
    cp -r inventories/_reference inventories/my-cluster

    # run a step: it plans first, then asks before applying
    ./cluster prepare:proxy        inventories/my-cluster/host.ini
    ./cluster bootstrap:rke2_server inventories/my-cluster/host.ini

The commented reference inventory is in `inventories/_reference/`. The convention
there is one config file per role, kept next to the machines that role runs on.

## How it is laid out

`catalog/` holds the steps, one sub-playbook each. `cluster.yaml` maps a tag to
its playbook. `playbooks/` has the bootstrap and clean wrappers. `tools/cluster/`
is the Go runner. `inventories/_reference/` is the inventory template.

The roles themselves are not in this repo. They are packaged in two public Ansible
Galaxy collections, `rridane.base_systems` for the host preparation and
`rridane.kubernetes_admin` for the cluster bootstrap. This repo is the
orchestration layer that ties them together.

## Why it is built this way

A few things I cared about while writing it. One config file maps to exactly one
role, scoped to the machines that role actually runs on, instead of a catch-all.
Steps are small and independent rather than one long playbook, so you can replay
any of them in isolation. And nothing runs without a plan first.

## License

MIT.
