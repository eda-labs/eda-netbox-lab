#!/usr/bin/env python
# /// script
# dependencies = ["requests"]
# ///
"""
Configure NetBox for EDA integration - creates webhooks, event rules, tags, and prefixes
"""

import sys
import time
import requests


def read_config_files():
    """Read configuration from saved files"""
    try:
        with open(".netbox_url", "r") as f:
            netbox_url = f.read().strip()
        with open(".eda_api_address", "r") as f:
            eda_api = f.read().strip()
        return netbox_url, eda_api
    except FileNotFoundError:
        print("Error: Configuration file not found. Run init.sh first.")
        sys.exit(1)


def get_api_token():
    """Get NetBox API token from Kubernetes secret"""
    import subprocess

    cmd = [
        "kubectl",
        "-n",
        "netbox",
        "get",
        "secret",
        "netbox-server-superuser",
        "-o",
        "jsonpath={.data.api_token}",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error getting API token: {result.stderr}")
        sys.exit(1)

    # Decode base64
    import base64

    return base64.b64decode(result.stdout).decode("utf-8")


class NetBoxConfigurator:
    def __init__(self, netbox_url, api_token):
        self.netbox_url = netbox_url.rstrip("/")
        self.headers = {
            "Authorization": f"Token {api_token}",
            "Content-Type": "application/json",
        }
        self.session = requests.Session()
        self.session.headers.update(self.headers)
        self.tenant_id = None
        self.site_id = None

    def get_tenant(self, name="eda"):
        """Get tenant created by EDA Instance"""
        response = self.session.get(f"{self.netbox_url}/api/tenancy/tenants/?name={name}")
        data = response.json()
        if data.get("count", 0) > 0:
            self.tenant_id = data["results"][0]["id"]
            return self.tenant_id
        return None

    def get_site(self, tenant_name="eda"):
        """Get site created by EDA Instance"""
        response = self.session.get(f"{self.netbox_url}/api/dcim/sites/?tenant={tenant_name}")
        data = response.json()
        if data.get("count", 0) > 0:
            self.site_id = data["results"][0]["id"]
            return self.site_id
        return None

    def wait_for_netbox(self, max_retries=30):
        """Wait for NetBox to be ready"""
        print("Waiting for NetBox to be ready...")
        for i in range(max_retries):
            try:
                response = self.session.get(f"{self.netbox_url}/api/")
                if response.status_code == 200:
                    print("NetBox is ready!")
                    return True
            except requests.exceptions.ConnectionError:
                pass
            print(f"Waiting... ({i + 1}/{max_retries})")
            time.sleep(10)
        return False

    def create_webhook(self, eda_api):
        """Create webhook for EDA integration"""
        print("Creating webhook...")

        # Check if webhook already exists
        response = self.session.get(f"{self.netbox_url}/api/extras/webhooks/?name=eda")
        if response.json()["count"] > 0:
            print("Webhook 'eda' already exists")
            return response.json()["results"][0]["id"]

        webhook_data = {
            "name": "eda",
            "payload_url": f"https://{eda_api}/core/httpproxy/v1/netbox/webhook/eda-netbox/netbox",
            "enabled": True,
            "http_method": "POST",
            "http_content_type": "application/json",
            "secret": "eda-netbox-webhook-secret",
            "ssl_verification": False,
        }

        response = self.session.post(
            f"{self.netbox_url}/api/extras/webhooks/", json=webhook_data
        )
        if response.status_code == 201:
            print("Webhook created successfully")
            return response.json()["id"]
        else:
            print(f"Error creating webhook: {response.text}")
            return None

    def create_event_rule(self, webhook_id):
        """Create or update the EDA event rule for the webhook"""
        print("Creating event rule...")

        required_object_types = [
            "dcim.site",
            "dcim.device",
            "dcim.cable",
            "dcim.devicetype",
            "ipam.ipaddress",
            "ipam.prefix",
            "ipam.vlangroup",
            "ipam.vlan",
            "ipam.asn",
            "ipam.asnrange",
        ]

        response = self.session.get(
            f"{self.netbox_url}/api/extras/event-rules/?name=eda"
        )
        data = response.json()
        if data["count"] > 0:
            event_rule = data["results"][0]
            event_rule_id = event_rule["id"]
            existing_types = set(event_rule.get("object_types", []))
            missing_types = set(required_object_types).difference(existing_types)
            updated_types = sorted(existing_types.union(required_object_types))
            needs_update = (
                bool(missing_types)
                or event_rule.get("action_object_id") != webhook_id
                or not event_rule.get("enabled", False)
            )
            if needs_update:
                patch_payload = {
                    "object_types": updated_types,
                    "action_object_id": webhook_id,
                    "enabled": True,
                }
                patch_response = self.session.patch(
                    f"{self.netbox_url}/api/extras/event-rules/{event_rule_id}/",
                    json=patch_payload,
                )
                if patch_response.status_code == 200:
                    print("Event rule 'eda' updated successfully")
                else:
                    print(
                        "Error updating event rule 'eda': "
                        f"{patch_response.status_code} {patch_response.text}"
                    )
            else:
                print("Event rule 'eda' already up to date")
            return

        event_rule_data = {
            "name": "eda",
            "object_types": required_object_types,
            "enabled": True,
            "event_types": ["object_created", "object_updated", "object_deleted"],
            "action_type": "webhook",
            "action_object_type": "extras.webhook",
            "action_object_id": webhook_id,
        }

        response = self.session.post(
            f"{self.netbox_url}/api/extras/event-rules/", json=event_rule_data
        )
        if response.status_code == 201:
            print("Event rule created successfully")
        else:
            print(f"Error creating event rule: {response.text}")

    def create_tags(self):
        """Create tags for EDA integration"""
        tags = [
            {"name": "eda-systemip-v4", "slug": "eda-systemip-v4", "color": "0066cc"},
            {"name": "eda-systemip-v6", "slug": "eda-systemip-v6", "color": "0066cc"},
            {"name": "eda-isl-v4", "slug": "eda-isl-v4", "color": "00cc66"},
            {"name": "eda-isl-v6", "slug": "eda-isl-v6", "color": "00cc66"},
            {"name": "eda-mgmt-v4", "slug": "eda-mgmt-v4", "color": "cc6600"},
            {"name": "eda-vlans", "slug": "eda-vlans", "color": "ff5722"},
            {"name": "eda-asns", "slug": "eda-asns", "color": "9e9e9e"},
        ]

        print("Creating tags...")
        for tag in tags:
            # Check if tag exists
            response = self.session.get(
                f"{self.netbox_url}/api/extras/tags/?name={tag['name']}"
            )
            if response.json()["count"] > 0:
                print(f"Tag '{tag['name']}' already exists")
                continue

            response = self.session.post(
                f"{self.netbox_url}/api/extras/tags/", json=tag
            )
            if response.status_code == 201:
                print(f"Tag '{tag['name']}' created successfully")
            else:
                print(f"Error creating tag '{tag['name']}': {response.text}")

    def create_vlan_groups(self):
        """Create VLAN groups used for EDA allocations"""
        vlan_groups = [
            {
                "name": "eda-vlans",
                "slug": "eda-vlans",
                "description": "EDA managed VLAN IDs",
                "vid_ranges": [[1, 300]],
                "tags": [{"name": "eda-vlans"}],
            }
        ]

        print("Creating VLAN groups...")
        for group in vlan_groups:
            response = self.session.get(
                f"{self.netbox_url}/api/ipam/vlan-groups/?name={group['name']}"
            )
            if response.json().get("count", 0) > 0:
                print(f"VLAN group '{group['name']}' already exists")
                continue

            create_response = self.session.post(
                f"{self.netbox_url}/api/ipam/vlan-groups/", json=group
            )
            if create_response.status_code == 201:
                print(f"VLAN group '{group['name']}' created successfully")
            else:
                print(
                    f"Error creating VLAN group '{group['name']}': "
                    f"{create_response.status_code} {create_response.text}"
                )

    def create_rir(self, slug="eda", name="eda"):
        """Create or correct the RIR required for ASN allocations"""
        response = self.session.get(
            f"{self.netbox_url}/api/ipam/rirs/?slug={slug}"
        )
        data = response.json()
        if data.get("count", 0) > 0:
            rir = data["results"][0]
            if rir.get("name") != name:
                patch_payload = {"name": name}
                patch_response = self.session.patch(
                    f"{self.netbox_url}/api/ipam/rirs/{rir['id']}/",
                    json=patch_payload,
                )
                if patch_response.status_code != 200:
                    print(
                        f"Warning: Unable to update RIR '{slug}' name: "
                        f"{patch_response.status_code} {patch_response.text}"
                    )
            return rir["id"]

        rir_payload = {
            "name": name,
            "slug": slug,
            "is_private": False,
            "description": "For EDA managed resources",
        }
        create_response = self.session.post(
            f"{self.netbox_url}/api/ipam/rirs/", json=rir_payload
        )
        if create_response.status_code == 201:
            rir = create_response.json()
            print(f"Created RIR '{name}' with ID {rir['id']}")
            return rir["id"]

        print(
            "Error: Unable to create RIR '"
            f"{name}' ({create_response.status_code} {create_response.text})"
        )
        return None

    def create_asn_ranges(self):
        """Create ASN ranges used for EDA allocations"""
        rir_id = self.create_rir()
        if rir_id is None:
            return

        asn_ranges = [
            {
                "name": "eda-asns",
                "slug": "eda-asns",
                "start": 65000,
                "end": 65100,
                "description": "EDA managed private ASNs",
                "rir": rir_id,
                "tags": [{"name": "eda-asns"}],
            }
        ]

        print("Creating ASN ranges...")
        for asn_range in asn_ranges:
            response = self.session.get(
                f"{self.netbox_url}/api/ipam/asn-ranges/?slug={asn_range['slug']}"
            )
            data = response.json()
            if data.get("count", 0) > 0:
                existing = data["results"][0]
                patch_payload = {
                    "name": asn_range["name"],
                    "start": asn_range["start"],
                    "end": asn_range["end"],
                    "description": asn_range["description"],
                    "rir": rir_id,
                    "tags": [dict(tag) for tag in asn_range["tags"]],
                }
                patch_response = self.session.patch(
                    f"{self.netbox_url}/api/ipam/asn-ranges/{existing['id']}/",
                    json=patch_payload,
                )
                if patch_response.status_code == 200:
                    print(f"ASN range '{asn_range['name']}' updated successfully")
                else:
                    print(
                        f"Error updating ASN range '{asn_range['name']}': "
                        f"{patch_response.status_code} {patch_response.text}"
                    )
                continue

            legacy_response = self.session.get(
                f"{self.netbox_url}/api/ipam/asn-ranges/?slug=eda-ans"
            )
            legacy_data = legacy_response.json()
            if legacy_data.get("count", 0) > 0:
                legacy = legacy_data["results"][0]
                patch_payload = {
                    "name": asn_range["name"],
                    "slug": asn_range["slug"],
                    "start": asn_range["start"],
                    "end": asn_range["end"],
                    "description": asn_range["description"],
                    "rir": rir_id,
                    "tags": [dict(tag) for tag in asn_range["tags"]],
                }
                patch_response = self.session.patch(
                    f"{self.netbox_url}/api/ipam/asn-ranges/{legacy['id']}/",
                    json=patch_payload,
                )
                if patch_response.status_code == 200:
                    print(
                        "Legacy ASN range 'eda-ans' migrated to 'eda-asns' successfully"
                    )
                else:
                    print(
                        "Error migrating legacy ASN range 'eda-ans': "
                        f"{patch_response.status_code} {patch_response.text}"
                    )
                continue

            create_response = self.session.post(
                f"{self.netbox_url}/api/ipam/asn-ranges/", json=asn_range
            )
            if create_response.status_code == 201:
                print(f"ASN range '{asn_range['name']}' created successfully")
            else:
                print(
                    f"Error creating ASN range '{asn_range['name']}': "
                    f"{create_response.status_code} {create_response.text}"
                )

    def create_prefixes(self):
        """Create example prefixes for EDA allocation pools"""
        prefixes = [
            {
                "prefix": "192.168.10.0/24",
                "status": "active",
                "description": "System IP pool for spine/leaf",
                "tags": [{"name": "eda-systemip-v4"}],
            },
            {
                "prefix": "10.0.0.0/16",
                "status": "container",
                "description": "ISL subnet pool",
                "tags": [{"name": "eda-isl-v4"}],
            },
            {
                "prefix": "2001:db8::/32",
                "status": "active",
                "description": "IPv6 System IP pool",
                "tags": [{"name": "eda-systemip-v6"}],
            },
            {
                "prefix": "2005::/64",
                "status": "container",
                "description": "IPv6 ISL subnet pool",
                "tags": [{"name": "eda-isl-v6"}],
            },
            {
                "prefix": "172.16.0.0/16",
                "status": "active",
                "description": "Management IP pool",
                "tags": [{"name": "eda-mgmt-v4"}],
            },
        ]

        print("Creating prefixes...")
        for prefix_data in prefixes:
            # Add tenant and site if available
            if self.tenant_id:
                prefix_data["tenant"] = self.tenant_id
            if self.site_id:
                prefix_data["site"] = self.site_id

            # Check if prefix exists
            response = self.session.get(
                f"{self.netbox_url}/api/ipam/prefixes/?prefix={prefix_data['prefix']}"
            )
            if response.json()["count"] > 0:
                existing = response.json()["results"][0]
                # Update tenant/site if missing
                patch_data = {}
                if self.tenant_id and not existing.get("tenant"):
                    patch_data["tenant"] = self.tenant_id
                if self.site_id and not existing.get("site"):
                    patch_data["site"] = self.site_id
                if patch_data:
                    patch_resp = self.session.patch(
                        f"{self.netbox_url}/api/ipam/prefixes/{existing['id']}/",
                        json=patch_data
                    )
                    if patch_resp.status_code == 200:
                        print(f"Prefix '{prefix_data['prefix']}' updated with tenant/site")
                    else:
                        print(f"Error updating prefix '{prefix_data['prefix']}': {patch_resp.text}")
                else:
                    print(f"Prefix '{prefix_data['prefix']}' already exists")
                continue

            response = self.session.post(
                f"{self.netbox_url}/api/ipam/prefixes/", json=prefix_data
            )
            if response.status_code == 201:
                print(f"Prefix '{prefix_data['prefix']}' created successfully")
            else:
                print(
                    f"Error creating prefix '{prefix_data['prefix']}': {response.text}"
                )


def main():
    """Main configuration function"""
    netbox_url, eda_api = read_config_files()
    api_token = get_api_token()

    print(f"NetBox URL: {netbox_url}")
    print(f"EDA API: {eda_api}")

    configurator = NetBoxConfigurator(netbox_url, api_token)

    # Wait for NetBox to be ready
    if not configurator.wait_for_netbox():
        print("NetBox is not ready. Please check the deployment.")
        sys.exit(1)

    # Configure NetBox - get EDA-created tenant and site
    configurator.get_tenant("eda")
    configurator.get_site("eda")
    configurator.create_tags()
    webhook_id = configurator.create_webhook(eda_api)
    if webhook_id:
        configurator.create_event_rule(webhook_id)
    configurator.create_prefixes()
    configurator.create_vlan_groups()
    configurator.create_asn_ranges()

    print("\nNetBox configuration completed!")
    print(f"You can now access NetBox at: {netbox_url}")
    print("Username: admin")
    print("Password: netbox")


if __name__ == "__main__":
    main()
