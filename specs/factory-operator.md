---
name: factory-operator
deps:
  - factory-agent-image
  - factory-operator-proxy-security
---

# Factory Operator

## Overview

The `factory operator` is a Kubernetes controller written in pure Go that implements a CRD-based interface for controlling the AI-factory sandboxes on GKE. It orchestrates the lifecycle of agent workers, provisioning their workspaces, configuring their egress proxies, and managing their runtime isolation boundaries. It enforces strict zero-trust security by launching workers on the `gvisor` runtime class with locked-down Kubernetes `NetworkPolicies`.

## Goals

- Implement the `factory operator` command inside the Go-based `factory` codebase.
- Avoid command-line flags, supporting only a single `--config <path>` flag which reads a multidoc KRM YAML file.
- Implement a Kubernetes controller that reconciles a custom resource (e.g., `AgentSandbox`) to manage Pods, PersistentVolumeClaims, and NetworkPolicies.
- Enforce strict runtime isolation using the `gvisor` runtime class for all launched agent Pods.
- Implement strict network isolation using `NetworkPolicy` to block direct ingress/egress from/to the internet and other pods, forcing all permitted external communication through the proxy.
- Provision storage using GKE-native `PersistentVolumeClaims` mapped to shared workspaces.

## Non-Goals

- Implementing non-Kubernetes container runtimes (like plain Docker, containerd directly, or systemd sandboxes).
- Implementing the proxy interceptor or CA certificate generation (covered in `factory-runtime-proxy` and `factory-runtime-proxy-tls`).
- Defining the agent CLI runtime prompt and execution harness (covered in `factory-agent-image`).

## Key Requirements

- **Command Layout**: Implement the operator command under `factory/cmd/factory/operator/operator.go`, aligned with the `factory` command's layout.
- **Multidoc Configuration**: Accept only `--config` as a flag. Parse a multidoc YAML configuration containing both global `FactoryConfig` and command-specific `OperatorConfig`.
- **gVisor Enforcement**: The operator must reject or fail to start any agent sandbox if the `gvisor` runtime class is not configured or fails to be specified in the Pod spec.
- **Network Lock-down**: The operator must deploy a `NetworkPolicy` per sandbox namespace or sandbox instance that denies all outbound traffic, with an explicit exception only for traffic directed to the companion reverse proxy.
- **Shared Storage**: The workspace directory must be on a PVC and mounted to both the cloning/self-test init containers and the main agent container.

## Design

### 1. Command Line Interface and Multi-doc Parsing
The operator command will be executed as follows:
```bash
factory operator --config /path/to/multidoc-config.yaml
```
- The config loader will read `/path/to/multidoc-config.yaml` and split it on the `---` YAML document separator.
- It will parse each document individually. It will extract and validate known KRM kinds:
  - `FactoryConfig` (for global options, cluster config, proxy defaults).
  - `OperatorConfig` (for operator-specific options like target namespace, storage classes, and worker images).

### 2. Custom Resource Definition (CRD)
The operator reconciles a custom resource defined as `AgentSandbox`:

```yaml
apiVersion: factory.ai.gke.io/v1alpha1
kind: AgentSandbox
metadata:
  name: example-task-sandbox
  namespace: factory-sandboxes
spec:
  agentName: codebase-investigator
  repository:
    url: https://github.com/ai-on-gke/ai-factory.git
    ref: main
    secretRef: github-clone-credentials
  proxy:
    policyName: task-12345-policy
  resources:
    cpu: "2"
    memory: "4Gi"
```

### 3. Controller Reconciliation Loop
The operator uses `controller-runtime` to monitor the state of `AgentSandbox` resources. On reconciliation:
1. **Namespace & Storage Preparation**:
   - Ensure a dedicated namespace or logical separation exists.
   - Create a `PersistentVolumeClaim` (PVC) using GKE's default or configured storage class to hold the workspace.
2. **Proxy Setup**:
   - Create the configuration configmap for the companion reverse proxy.
   - Launch the proxy container/Pod.
3. **Network Isolation**:
   - Deploy a `NetworkPolicy` that matches the sandbox Pod.
   - Configure the policy to deny all default egress, except for traffic to the proxy's IP/port.
   - Deny all default ingress.
4. **Agent Pod Dispatch**:
   - Launch the agent Pod with:
     - `runtimeClassName: gvisor`
     - **Init Container 1**: Git clone utility. Mounts the workspace PVC and clone credentials. Clones the repository.
     - **Init Container 2**: Self-test network validator. Mounts the workspace PVC. Performs DNS and external IP checks, then tests proxy ping before resolving.
     - **Main Container**: Mounts the workspace PVC. Sets up `HTTPS_PROXY` pointing to the proxy and `NODE_EXTRA_CA_CERTS`. Runs the agent harness.
5. **Status Tracking**:
   - Track Pod lifecycle phases (Pending, Running, Succeeded, Failed) and surface them in the `AgentSandbox` CRD status block, including logs or status summaries if appropriate.

## Examples

### Multidoc Configuration
```yaml
apiVersion: factory.ai.gke.io/v1alpha1
kind: FactoryConfig
metadata:
  name: factory-global-config
options:
  clusterName: gke-ai-factory-cluster
---
apiVersion: factory.ai.gke.io/v1alpha1
kind: OperatorConfig
metadata:
  name: operator-config
options:
  targetNamespace: factory-sandboxes
  workerImage: gcr.io/gke-ai-factory/agent-worker:latest
  storageClass: premium-rwo
```

## Tests

- **Config Parsing Tests**: Unit tests verifying that multidoc configs can be split and loaded into separate Go structs correctly, and that invalid kinds or missing options trigger immediate errors.
- **Controller Dry-Run (envtest) Tests**: Reconcile an `AgentSandbox` custom resource against a mock Kubernetes API control plane to verify that:
  - A PVC is created with the correct storage class and size.
  - A NetworkPolicy is generated with correct egress blocks restricting access to the proxy.
  - A Pod is created specifying `runtimeClassName: gvisor` along with the correct init containers and volume mounts.
- **E2E Controller Tests**: Run the operator on a live test GKE cluster. Create an `AgentSandbox` object and verify that the workspace is cloned, the self-test validates isolation, the agent executes, and status changes are accurately written back to the CRD.
