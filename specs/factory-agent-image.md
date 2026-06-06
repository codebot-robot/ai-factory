---
name: factory-agent-image
deps: []
---

# Factory Agent Image

## Overview

This specification details the design and requirements for the container image and init container behaviors that make up the `ai-on-gke-agent`. The agent container image runs an agent harness powered by `gemini-cli` to execute software engineering tasks inside a secure Kubernetes sandbox. To prevent security leaks, the environment uses an init container to perform network isolation self-tests and clone source code repositories before the main agent execution starts.

## Goals

- Define the container image structure containing `node`, `git`, and `@google/gemini-cli`.
- Detail the network self-test init container that validates Kubernetes NetworkPolicy enforcement before starting the agent.
- Spec the repository cloning init container that prepares the workspace inside a shared PersistentVolumeClaim (PVC).
- Ensure credentials and network configurations are managed securely and decoupled from the main agent container runtime.

## Non-Goals

- Implementing the actual Kubernetes operator logic (covered in `factory-operator`).
- Implementing the reverse proxy server logic (covered in `factory-runtime-proxy` and `factory-runtime-proxy-tls`).
- Providing dynamic workspace reloading after the main agent execution has started.

## Key Requirements

- **Base Image**: Standardize on a slim Node.js LTS base image to minimize size and attack surface while retaining NPM capabilities.
- **Self-Test Validation**: The self-test init container must fail immediately if it can resolve cluster-internal DNS, reach external networks like `8.8.8.8`, or if it cannot reach the configured reverse proxy.
- **Secure Credentials**: Repository cloning credentials must be mounted only to the cloning init container and not exposed to the main agent container.
- **Idempotency**: The cloning process must handle pre-existing directories on the PVC gracefully if a task is restarted.

## Design

### 1. Container Image Structure
The main agent image will be built from a Node.js slim base image (e.g., `node:20-slim`).
- Install standard utilities: `git`, `openssh-client`, and common build essentials if needed.
- Globally install `@google/gemini-cli` or run it via a pre-installed package bundle.
- Configure default environment variables:
  - `GEMINI_CLI_TRUST_WORKSPACE=true`
  - `GEMINI_API_KEY=fake` (to ensure it forces use of the reverse proxy instead of direct API access if direct egress is somehow bypassed)

### 2. Self-Test Init Container
To prevent misconfiguration, an init container (or the main entrypoint starting in a restricted mode) must perform a network sanity check.
- **Cluster-internal DNS check**: Try to resolve a standard GKE DNS address (e.g., `kubernetes.default.svc.cluster.local`). This check must fail or timeout.
- **External IP check**: Try to connect to a public IP address (e.g., `8.8.8.8:53` or `8.8.8.8:443`). This check must fail or timeout.
- **Proxy connectivity check**: Send a health check request or TCP connect to the designated local reverse proxy address (e.g., `http://factory-proxy.local:8080/healthz` or the configured proxy host). This check must succeed.
- If any of these checks violate the expected isolation policies, the container must print a descriptive error and exit with a non-zero code to halt the Pod startup.

### 3. Cloning Init Container
The operator mounts a shared `PersistentVolumeClaim` (PVC) into the Pod. Before the agent starts:
- A dedicated git-clone init container mounts the same PVC.
- It reads configuration (repository URL, branch/ref, and credentials) from environment variables or mounted secrets.
- It clones the target repository into the shared volume.
- Credentials (such as SSH private keys or HTTPS access tokens) are mounted as read-only volumes *only* to this init container. They are omitted from the main agent container's spec so the running agent never has access to the primary credentials.

### 4. Main Entrypoint Behavior
Once the init containers succeed, the main agent container starts:
- It mounts the shared PVC containing the cloned workspace at a target path (e.g., `/workspace`).
- It configures `HTTPS_PROXY` (or `HTTP_PROXY`) and `NODE_EXTRA_CA_CERTS` to route all outbound requests through the reverse proxy.
- It reads the requested agent's prompt from the workspace (e.g. `.agents/${AGENT_NAME}/agent.md`).
- It executes `gemini-cli` in YOLO mode (`gemini --yolo`) to run the requested task.

## Examples

### Self-Test Bash Script Implementation
An example script run by the self-test init container:
```bash
#!/bin/bash
set -e

echo "Running Network Security Self-Test..."

# 1. Check internal DNS (should fail)
if getent hosts kubernetes.default.svc.cluster.local > /dev/null 2>&1; then
  echo "SECURITY FAILURE: Cluster-internal DNS is reachable!"
  exit 1
fi

# 2. Check external IP (should fail/timeout)
if curl --connect-timeout 3 http://8.8.8.8 > /dev/null 2>&1; then
  echo "SECURITY FAILURE: Direct external network (8.8.8.8) is reachable!"
  exit 1
fi

# 3. Check proxy connectivity (should succeed)
if ! curl --connect-timeout 5 -k https://factory-proxy.local:8443/healthz > /dev/null 2>&1; then
  echo "FAILURE: Reverse proxy is unreachable!"
  exit 1
fi

echo "Network isolation self-test passed."
```

## Tests

- **Self-Test Script Isolation Tests**: Unit tests for the self-test script within mock environments to verify that it fails when internet access is directly available or when the proxy is missing, and passes only under the exact desired network policy constraints.
- **Clone Init Container Tests**: Integration tests verifying that the clone init container correctly fetches the repository using provided secrets, writes it to the shared volume, and that the main container cannot access those secrets.
- **Container E2E Execution**: Verify the built container runs correctly on a mock/test Kubernetes cluster, executes the init steps, runs the self-test, and executes a basic `gemini-cli` operation through the proxy.
