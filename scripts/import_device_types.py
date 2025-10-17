#!/usr/bin/env python
# /// script
# dependencies = [
#     "requests",
# ]
# ///
"""Import NetBox device types from the community library using the official importer."""

import argparse
import subprocess
import sys
import time
import textwrap
from pathlib import Path
from typing import List

import requests
from urllib3.exceptions import InsecureRequestWarning

requests.packages.urllib3.disable_warnings(category=InsecureRequestWarning)


DEFAULT_LIBRARY_URL = "https://github.com/netbox-community/devicetype-library.git"
DEFAULT_LIBRARY_BRANCH = "master"
DEFAULT_K8S_NAMESPACE = "netbox"
DEFAULT_CLUSTER_NETBOX_URL = "http://netbox-server.netbox.svc.cluster.local"


def read_netbox_url() -> str:
    path = Path(".netbox_url")
    if not path.exists():
        raise FileNotFoundError("Missing .netbox_url. Run init.sh to deploy NetBox first.")
    return path.read_text().strip()


def wait_for_netbox(url: str, retries: int = 30, delay: int = 5) -> None:
    """Poll the NetBox API root until it responds with HTTP 200."""
    for attempt in range(1, retries + 1):
        try:
            response = requests.get(f"{url.rstrip('/')}/api/", timeout=10, verify=False)
            if response.status_code == 200:
                return
        except requests.RequestException:
            pass
        time.sleep(delay)
    raise TimeoutError(
        "Timed out waiting for NetBox API to respond. Verify that the deployment is healthy."
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Import device types from the NetBox Device Type Library",
    )
    parser.add_argument(
        "--vendors",
        default="nokia",
        help="Comma-separated list of vendors to import (default: nokia)",
    )
    parser.add_argument(
        "--library-url",
        default=DEFAULT_LIBRARY_URL,
        help="Git URL for the NetBox Device Type Library",
    )
    parser.add_argument(
        "--library-branch",
        default=DEFAULT_LIBRARY_BRANCH,
        help="Git branch of the NetBox Device Type Library",
    )
    parser.add_argument(
        "--k8s-namespace",
        default=DEFAULT_K8S_NAMESPACE,
        help="Namespace where the importer job should run (default: netbox)",
    )
    parser.add_argument(
        "--cluster-netbox-url",
        default=DEFAULT_CLUSTER_NETBOX_URL,
        help=(
            "Internal NetBox URL to pass to the Kubernetes job "
            "(default: http://netbox-server.netbox.svc.cluster.local)"
        ),
    )
    parser.add_argument(
        "--importer-image",
        default="ghcr.io/minitriga/netbox-device-type-library-import:latest",
        help="Container image to use for the Kubernetes job",
    )
    return parser.parse_args()


def render_job_manifest(
    job_name: str,
    namespace: str,
    image: str,
    netbox_url: str,
    vendors: List[str],
    library_url: str,
    library_branch: str,
) -> str:
    vendor_value = ",".join(vendors)
    # Build YAML manually to avoid adding PyYAML dependency for the controller.
    lines = [
        "apiVersion: batch/v1",
        "kind: Job",
        f"metadata:",
        f"  name: {job_name}",
        f"  namespace: {namespace}",
        "spec:",
        "  ttlSecondsAfterFinished: 600",
        "  template:",
        "    spec:",
        "      restartPolicy: Never",
        "      containers:",
        "      - name: importer",
        f"        image: {image}",
        "        env:",
        f"        - name: NETBOX_URL",
        f"          value: \"{netbox_url.rstrip('/')}\"",
        "        - name: VENDORS",
        f"          value: \"{vendor_value}\"",
        "        - name: REPO_URL",
        f"          value: \"{library_url}\"",
        "        - name: REPO_BRANCH",
        f"          value: \"{library_branch}\"",
        "        - name: NETBOX_TOKEN",
        "          valueFrom:",
        "            secretKeyRef:",
        "              name: netbox-server-superuser",
        "              key: api_token",
    ]
    return "\n".join(lines)


def run_importer_job(
    namespace: str,
    netbox_url: str,
    vendors: List[str],
    image: str,
    library_url: str,
    library_branch: str,
    timeout_seconds: int = 900,
) -> None:
    job_name = f"netbox-dtl-import-{int(time.time())}"
    manifest = render_job_manifest(
        job_name,
        namespace,
        image,
        netbox_url,
        vendors,
        library_url,
        library_branch,
    )

    apply = subprocess.run(
        ["kubectl", "apply", "-f", "-"],
        input=manifest,
        text=True,
        capture_output=True,
        check=False,
    )
    if apply.returncode != 0:
        raise RuntimeError(
            "Failed to create importer job: " + apply.stderr.strip()
        )

    try:
        wait_cmd = [
            "kubectl",
            "wait",
            f"--for=condition=complete",
            f"job/{job_name}",
            "-n",
            namespace,
            f"--timeout={timeout_seconds}s",
        ]
        wait = subprocess.run(wait_cmd, capture_output=True, text=True, check=False)
        if wait.returncode != 0:
            describe = subprocess.run(
                ["kubectl", "describe", f"job/{job_name}", "-n", namespace],
                text=True,
                capture_output=True,
            )
            raise RuntimeError(
                "Importer job did not complete successfully:\n"
                + wait.stderr.strip()
                + ("\n\nJob description:\n" + describe.stdout if describe.stdout else "")
            )
    finally:
        logs = subprocess.run(
            ["kubectl", "logs", f"job/{job_name}", "-n", namespace],
            text=True,
            capture_output=True,
        )
        if logs.stdout:
            print(textwrap.indent(logs.stdout.strip(), "    "))
        if logs.stderr:
            print(textwrap.indent(logs.stderr.strip(), "    "), file=sys.stderr)



def main() -> None:
    args = parse_args()
    vendors = [v.strip() for v in args.vendors.split(",") if v.strip()]
    if not vendors:
        raise ValueError("At least one vendor must be specified for import.")

    netbox_url = read_netbox_url()
    wait_for_netbox(netbox_url)

    run_importer_job(
        namespace=args.k8s_namespace,
        netbox_url=args.cluster_netbox_url or netbox_url,
        vendors=vendors,
        image=args.importer_image,
        library_url=args.library_url,
        library_branch=args.library_branch,
    )


if __name__ == "__main__":
    main()
