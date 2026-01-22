#!/usr/bin/env python
# /// script
# dependencies = ["requests"]
# ///
"""
Cleanup NetBox - reverts what configure_netbox.py creates
(webhook, event rule, tags, prefixes, VLAN groups, ASN ranges, RIR)
"""

import sys
import requests


def get_script_dir():
    """Get the directory where this script is located"""
    import os
    return os.path.dirname(os.path.abspath(__file__))


def get_project_root():
    """Get project root (parent of scripts dir)"""
    import os
    return os.path.dirname(get_script_dir())


def read_config_files():
    """Read configuration from saved files"""
    import os
    project_root = get_project_root()
    netbox_url_path = os.path.join(project_root, ".netbox_url")
    try:
        with open(netbox_url_path, "r") as f:
            netbox_url = f.read().strip()
        return netbox_url
    except FileNotFoundError:
        print(f"Error: {netbox_url_path} not found. Run init.sh first.")
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

    import base64

    return base64.b64decode(result.stdout).decode("utf-8")


class NetBoxCleaner:
    """Reverts what configure_netbox.py creates"""

    # Items created by configure_netbox.py
    TAGS = [
        "eda-systemip-v4",
        "eda-systemip-v6",
        "eda-isl-v4",
        "eda-isl-v6",
        "eda-mgmt-v4",
        "eda-vlans",
        "eda-asns",
    ]
    PREFIXES = [
        "192.168.10.0/24",
        "10.0.0.0/16",
        "2001:db8::/32",
        "2005::/64",
        "172.16.0.0/16",
    ]
    VLAN_GROUPS = ["eda-vlans"]
    ASN_RANGES = ["eda-asns"]
    RIRS = ["eda"]
    WEBHOOKS = ["eda"]
    EVENT_RULES = ["eda"]
    SITES_BY_TENANT = ["eda"]  # Delete sites belonging to this tenant

    def __init__(self, netbox_url, api_token):
        self.netbox_url = netbox_url.rstrip("/")
        self.headers = {
            "Authorization": f"Token {api_token}",
            "Content-Type": "application/json",
        }
        self.session = requests.Session()
        self.session.headers.update(self.headers)

    def delete_by_name(self, endpoint, name, lookup_field="name"):
        """Delete a single object by name"""
        response = self.session.get(
            f"{self.netbox_url}/api/{endpoint}/",
            params={lookup_field: name}
        )
        if response.status_code != 200:
            print(f"  Error looking up {name}: {response.status_code}")
            return False

        data = response.json()
        if data.get("count", 0) == 0:
            return False

        item = data["results"][0]
        del_response = self.session.delete(
            f"{self.netbox_url}/api/{endpoint}/{item['id']}/"
        )
        if del_response.status_code in (204, 200):
            print(f"  Deleted: {name}")
            return True
        else:
            print(f"  Failed to delete {name}: {del_response.status_code}")
            return False

    def delete_by_prefix(self, prefix):
        """Delete a prefix by its CIDR"""
        response = self.session.get(
            f"{self.netbox_url}/api/ipam/prefixes/",
            params={"prefix": prefix}
        )
        if response.status_code != 200:
            print(f"  Error looking up prefix {prefix}: {response.status_code}")
            return False

        data = response.json()
        if data.get("count", 0) == 0:
            return False

        item = data["results"][0]
        del_response = self.session.delete(
            f"{self.netbox_url}/api/ipam/prefixes/{item['id']}/"
        )
        if del_response.status_code in (204, 200):
            print(f"  Deleted: {prefix}")
            return True
        else:
            print(f"  Failed to delete {prefix}: {del_response.status_code}")
            return False

    def delete_sites_by_tenant(self, tenant_name):
        """Delete all sites belonging to a tenant"""
        response = self.session.get(
            f"{self.netbox_url}/api/dcim/sites/",
            params={"tenant": tenant_name}
        )
        if response.status_code != 200:
            print(f"  Error looking up sites for tenant {tenant_name}: {response.status_code}")
            return 0

        data = response.json()
        deleted = 0
        for site in data.get("results", []):
            del_response = self.session.delete(
                f"{self.netbox_url}/api/dcim/sites/{site['id']}/"
            )
            if del_response.status_code in (204, 200):
                print(f"  Deleted site: {site['name']}")
                deleted += 1
            else:
                print(f"  Failed to delete site {site['name']}: {del_response.status_code}")
        return deleted

    def delete_all_custom_fields(self):
        """Delete all custom fields"""
        deleted = 0
        while True:
            response = self.session.get(
                f"{self.netbox_url}/api/extras/custom-fields/",
                params={"limit": 100}
            )
            if response.status_code != 200:
                print(f"  Error fetching custom fields: {response.status_code}")
                break

            data = response.json()
            results = data.get("results", [])
            if not results:
                break

            for cf in results:
                del_response = self.session.delete(
                    f"{self.netbox_url}/api/extras/custom-fields/{cf['id']}/"
                )
                if del_response.status_code in (204, 200):
                    print(f"  Deleted custom field: {cf['name']}")
                    deleted += 1
                else:
                    print(f"  Failed to delete custom field {cf['name']}: {del_response.status_code}")
        return deleted

    def run_cleanup(self):
        """Revert configure_netbox.py changes"""
        print("=" * 50)
        print("NetBox Cleanup (reverting configure_netbox.py)")
        print("=" * 50)
        print("")

        print("Deleting event rules...")
        for name in self.EVENT_RULES:
            self.delete_by_name("extras/event-rules", name)

        print("Deleting webhooks...")
        for name in self.WEBHOOKS:
            self.delete_by_name("extras/webhooks", name)

        print("Deleting prefixes...")
        for prefix in self.PREFIXES:
            self.delete_by_prefix(prefix)

        print("Deleting sites by tenant...")
        for tenant in self.SITES_BY_TENANT:
            self.delete_sites_by_tenant(tenant)

        print("Deleting VLAN groups...")
        for name in self.VLAN_GROUPS:
            self.delete_by_name("ipam/vlan-groups", name)

        print("Deleting ASN ranges...")
        for slug in self.ASN_RANGES:
            self.delete_by_name("ipam/asn-ranges", slug, lookup_field="slug")

        print("Deleting RIRs...")
        for slug in self.RIRS:
            self.delete_by_name("ipam/rirs", slug, lookup_field="slug")

        print("Deleting tags...")
        for name in self.TAGS:
            self.delete_by_name("extras/tags", name)

        print("Deleting custom fields...")
        self.delete_all_custom_fields()

        print("")
        print("=" * 50)
        print("Cleanup completed!")
        print("=" * 50)


def main():
    """Main function"""
    import argparse

    parser = argparse.ArgumentParser(
        description="Cleanup NetBox - reverts configure_netbox.py changes"
    )
    parser.add_argument(
        "--yes", "-y",
        action="store_true",
        help="Skip confirmation prompt"
    )
    args = parser.parse_args()

    netbox_url = read_config_files()
    api_token = get_api_token()

    print(f"NetBox URL: {netbox_url}")

    if not args.yes:
        print("\nThis will delete EDA-related objects (webhook, tags, prefixes, etc.)")
        confirm = input("Continue? (yes/no): ")
        if confirm.lower() != "yes":
            print("Aborted.")
            sys.exit(0)

    cleaner = NetBoxCleaner(netbox_url, api_token)
    cleaner.run_cleanup()


if __name__ == "__main__":
    main()
