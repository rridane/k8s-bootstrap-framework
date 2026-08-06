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

## It runs a real cluster

I use this to run my own cluster, not as a demo. It bootstrapped, and still grows:

- **3 control-plane nodes** on OVH Public Cloud (Gravelines),
- **3 SYS-1 bare-metal workers** (Roubaix), joined to the control plane over a
  cross-datacenter **vRack**,
- **RKE2 in kube-proxy-free mode** (Cilium eBPF), with **kube-vip** holding the
  API VIP and Cilium L2 announcing the ingress VIP — no hardware load balancer.

The runner plans, asks, then applies. Here it is adding a worker, and the result:

    $ ./cluster prepare:netplan inventories/admin/host.ini --limit worker-2
    ── plan (--check --diff) ──
    TASK [system_configure_netplan : Render configuration]
    + network:
    +   ethernets:
    +     eno2:
    +       addresses: [10.0.0.102/24]
    Appliquer ces changements ?  [yes/no] yes
    ── apply ──
    changed: [worker-2]

    $ kubectl get nodes
    NAME       STATUS   ROLES                VERSION
    master-0   Ready    control-plane,etcd   v1.35.6+rke2r1
    master-1   Ready    control-plane,etcd   v1.35.6+rke2r1
    master-2   Ready    control-plane,etcd   v1.35.6+rke2r1
    worker-0   Ready    <none>               v1.35.6+rke2r1
    worker-1   Ready    <none>               v1.35.7+rke2r1
    worker-2   Ready    <none>               v1.35.7+rke2r1

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

    # 1. the Ansible runtime — ansible-core >= 2.16 (needed for Python 3.12 targets)
    python3 -m venv .venv && source .venv/bin/activate
    pip install -r requirements.txt

    # 2. the roles, from Ansible Galaxy
    ansible-galaxy collection install -r requirements.yml -p collections

    # 3. the runner (the go.mod lives in tools/cluster)
    (cd tools/cluster && go build -o ../../cluster .)

    # 4. copy the reference inventory and adapt it to your machines
    cp -r inventories/_reference inventories/my-cluster

    # 5. run a single step — it plans, asks, then applies
    ./cluster prepare:time          inventories/my-cluster/host.ini
    ./cluster bootstrap:rke2_agents inventories/my-cluster/host.ini

The commented reference inventory is in `inventories/_reference/`. The convention
there is one config file per role, kept next to the machines that role runs on.

## Per-target pipeline

A target can declare which steps it actually runs, in an
`inventories/<target>/pipeline.yaml`:

    prepare:   [time, netplan, etc_hosts, network_rules, swap]
    configure: [rke2_cilium, rke2_kubevip]
    bootstrap: [rke2_primary, rke2_servers, rke2_agents]

Then a whole phase plays exactly those steps, in catalog order — nothing else:

    ./cluster pipeline inventories/my-cluster/host.ini    # show what will run
    ./cluster phase prepare inventories/my-cluster/host.ini

## How it is laid out

`catalog/` holds the steps, one sub-playbook each. `cluster.yaml` maps a tag to
its playbook. `playbooks/` has the bootstrap and clean wrappers. `tools/cluster/`
is the Go runner. `inventories/_reference/` is the inventory template.

## The roles live in two collections

The logic isn't in this repo. The roles are packaged in two public Ansible Galaxy
collections — `rridane.base_systems` for the host preparation and
`rridane.kubernetes_admin` for the cluster bootstrap. This repo is the
orchestration layer on top: the catalogue, the routing, and the runner.

## Why it is built this way

A few things I cared about while writing it. One config file maps to exactly one
role, scoped to the machines that role actually runs on, instead of a catch-all.
Steps are small and independent rather than one long playbook, so you can replay
any of them in isolation. And nothing runs without a plan first.

## License

MIT.
