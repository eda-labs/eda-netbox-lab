# Nokia EDA NetBox Lab

[![Discord][discord-svg]][discord-url]

[discord-svg]: https://gitlab.com/rdodin/pics/-/wikis/uploads/b822984bc95d77ba92d50109c66c7afe/join-discord-btn.svg
[discord-url]: https://eda.dev/discord

When IPAM data and automation live in different systems, network provisioning quickly drifts from the intended design. The Nokia EDA NetBox lab demonstrates how the [**Nokia Event Driven Automation**](https://docs.eda.dev/) platform can stay in sync with NetBox: allocation pools are generated straight from tagged prefixes, SR Linux fabrics consume those pools, and every assignment is written back to the source of truth.

In its default form the lab runs entirely inside the EDA Digital Twin (CX) environment: the topology, NetBox instance, and integration resources are deployed with a single script. A Containerlab option is available for environments running EDA with `Simulate=False`—see the dedicated guide in [`clab/README.md`](./clab/README.md).

## Lab Components

- **EDA Digital Twin (CX):** Provides simulated SR Linux nodes (2× spines, 2× leafs) and two Linux application servers.
- **NetBox:** Installed via Helm inside Kubernetes; exposes a UI and API secured with secrets consumed by EDA.
- **EDA NetBox Application:** Processes NetBox webhooks, creates allocation pools, and reconciles changes back to NetBox.
- **Fabric Manifests:** Reference NetBox-managed pools so SR Linux provisioning always matches the IPAM intent.
- **Helper Scripts:** `./cx/node-ssh`, `./cx/container-shell`, and `scripts/configure_netbox.py` streamline everyday operations.

## Requirements

> [!IMPORTANT]
> **EDA Version:** 25.8.2 or later. Ensure your EDA playground (or production deployment) is installed and healthy before starting the lab.

1. **Helm** – install from <https://helm.sh/docs/intro/install/>.
2. **kubectl** – verify the EDA engine status:
   ```bash
   kubectl -n eda-system get engineconfig engine-config \
     -o jsonpath='{.status.run-status}{"\n"}'
   ```
   Expected output: `Started`
3. **Local shell access** to the EDA cluster. No additional tooling is required; the init script installs `uv` and `clab-connector` when needed.

## 🚀 Lab Deployment

The `init.sh` script performs the entire CX deployment flow:

- Bootstraps the `eda-netbox` namespace (CX only)
- Loads the SR Linux topology into CX and configures the server containers
- Installs NetBox via Helm and waits for the service to become reachable
- Creates Kubernetes secrets for the NetBox API token and webhook signature
- Applies the NetBox integration manifests (`manifests/*.yaml`)
- Runs `scripts/configure_netbox.py` to create tags, prefixes, webhooks, and event rules in NetBox

```bash
./init.sh
```

> [!NOTE]
> The script detects CX automatically. If CX pods are not present it prepares the environment for the Containerlab workflow—follow the instructions in [`clab/README.md`](./clab/README.md) to continue with that path.

### Verify Deployment

1. **NetBox UI:** The URL is printed at the end of `init.sh` and stored in `.netbox_url`. Default credentials: `admin` / `netbox`.
2. **EDA Namespace:**
   ```bash
   kubectl get toponode -n eda-netbox
   kubectl get allocation -n eda-netbox
   ```
3. **Webhook Logs:**
   ```bash
   kubectl logs -n eda-system -l app=netbox --tail 100
   ```

## Accessing Network Elements

- **SR Linux nodes (CX):** `./cx/node-ssh leaf1`
- **Server containers (CX):** `./cx/container-shell server1`
- **NetBox API token:** stored as the `netbox-api-token` secret in the `eda-netbox` namespace
- **EDA API endpoint:** saved locally in `.eda_api_address` for use with `clab-connector` or custom tooling

## Working with NetBox Integration

- **Prefixes & Tags:** Examples (e.g., `eda-systemip-v4`, `eda-isl-v4`) are created automatically. Add your own prefixes in NetBox using the same tags to provision additional pools.
- **Allocations:** Every pool is mirrored into EDA as an `Allocation` CR. Watch updates with:
  ```bash
  kubectl get allocation -n eda-netbox
  ```
- **Fabric:** The sample `Fabric` resource (`manifests/0060_fabric.yaml`) references the NetBox-managed pools and runs EBGP across the spine-leaf topology.

## Containerlab Variant

Running EDA with `Simulate=False` and external SR Linux nodes? After `./init.sh` completes, follow [`clab/README.md`](./clab/README.md) to deploy the Containerlab topology, import it with `clab-connector`, and access the physical or virtual nodes.

## Cleanup

```bash
./cleanup.sh
# Optional: remove the Containerlab topology if used
containerlab destroy -t eda-nb.clab.yaml
# Optional: delete the namespace when testing different scenarios
kubectl delete namespace eda-netbox --wait=false
```

## Additional Resources

- [EDA NetBox App Guide](https://docs.eda.dev/25.4/apps/netbox/)
- [NetBox Documentation](https://docs.netbox.dev/)
- [Containerlab Documentation](https://containerlab.dev/)
