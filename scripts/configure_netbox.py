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
        """Create event rule for webhook"""
        print("Creating event rule...")

        # Check if event rule already exists
        response = self.session.get(
            f"{self.netbox_url}/api/extras/event-rules/?name=eda"
        )
        if response.json()["count"] > 0:
            print("Event rule 'eda' already exists")
            return

        event_rule_data = {
            "name": "eda",
            "object_types": ["ipam.ipaddress", "ipam.prefix"],
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
            # Check if prefix exists
            response = self.session.get(
                f"{self.netbox_url}/api/ipam/prefixes/?prefix={prefix_data['prefix']}"
            )
            if response.json()["count"] > 0:
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

    # Configure NetBox
    configurator.create_tags()
    webhook_id = configurator.create_webhook(eda_api)
    if webhook_id:
        configurator.create_event_rule(webhook_id)
    configurator.create_prefixes()

    print("\nNetBox configuration completed!")
    print(f"You can now access NetBox at: {netbox_url}")
    print("Username: admin")
    print("Password: netbox")


if __name__ == "__main__":
    main()
