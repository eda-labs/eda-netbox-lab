# 📦 Containerlab Deployment

- **EDA Mode:** `Simulate=False` – integrates external Containerlab SR Linux nodes
- **Namespace:** `eda-netbox`
- **Automation:** `init.sh` installs NetBox, seeds secrets, and applies manifests. Containerlab brings up the fabric.
- **License:** Requires a valid EDA hardware license (25.8+) when running with Simulate=False.
- **Traffic Generation:** Basic nginx workloads on server containers (can be extended with your own tooling).

> [!IMPORTANT]
> Install EDA in `Simulate=False` mode for Containerlab deployments. Follow the [official instructions][sim-false-doc] and ensure your license is active before starting the lab.

[sim-false-doc]: https://docs.eda.dev/user-guide/containerlab-integration/#installing-eda

## Common Requirements

1. **EDA (25.8.2+)** with Simulate=False mode
2. **Helm** – <https://helm.sh/docs/intro/install/>
3. **kubectl** – verify EDA status:
   ```bash
   kubectl -n eda-system get engineconfig engine-config \
     -o jsonpath='{.status.run-status}{"\n"}'
   ```
   Expected output: `Started`
4. **Containerlab** – install from <https://containerlab.dev/install/>

## Step 1: Initialize the Lab

Run the installer script once. It installs dependencies (`uv`, `clab-connector`), deploys NetBox via Helm, creates the secrets in `eda-netbox`, and applies the integration manifests.

```bash
./init.sh
```

## Step 2: Deploy the Containerlab Topology

```bash
containerlab deploy -t eda-nb.clab.yaml
```

The topology spins up two spines, two leafs, and two Linux servers. Artifacts (inventory, topology-data) land under `./clab-eda-nb/`.

## Step 3: Integrate Containerlab with EDA

```bash
clab-connector integrate \
  --topology-data clab-eda-nb/topology-data.json \
  --eda-url "https://$(cat .eda_api_address)" \
  --namespace eda-netbox \
  --skip-edge-intfs
```

> [!IMPORTANT]
> `--skip-edge-intfs` is required. The lab attaches server interfaces through manifests, so leave the edge links untouched.

## Step 4: Validate the Deployment

1. **NetBox UI:** Open the URL stored in `.netbox_url` (`admin` / `netbox`)
2. **EDA namespace:**
   ```bash
   kubectl get toponode -n eda-netbox
   kubectl get allocation -n eda-netbox
   ```
3. **Webhook logs:**
   ```bash
   kubectl logs -n eda-system -l app=netbox --tail 50
   ```

## Accessing the Nodes

| Node Type | Access Example | Notes |
|-----------|----------------|-------|
| SR Linux | `ssh admin@clab-eda-nb-leaf1` | Password `NokiaSrl1!` |
| Servers | `ssh admin@clab-eda-nb-server1` | Password `multit00l` |

## Customising the Lab

- Add or modify prefixes in NetBox (tagged with `eda-*`) to create new allocation pools on the fly
- Extend the fabric by editing `manifests/0060_fabric.yaml`
- Build additional automation on top of the secrets created in `eda-netbox`

## Cleanup

```bash
./cleanup.sh
containerlab destroy -t eda-nb.clab.yaml
```

> [!TIP]
> `cleanup.sh` leaves the `eda-netbox` namespace in place. Run `kubectl delete namespace eda-netbox --wait=false` if you want a completely clean slate before redeploying.
