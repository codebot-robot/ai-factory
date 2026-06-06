---
name: factory-operator-proxy-security
deps:
  - factory-runtime-proxy
  - factory-runtime-proxy-tls
---

# Factory Operator Proxy Security

## Overview

This specification details the security integration between the `factory operator` and the egress reverse proxy. In the `ai-factory` architecture, agent sandboxes must be completely isolated and forbidden from accessing the internet directly. However, they need secure, controlled access to LLM APIs and external tools (e.g., GitHub, package managers, GCP APIs). This specification outlines how the reverse proxy acts as an intelligent security gateway by enforcing independent security policies per sandbox, hosting secrets on behalf of the agent, and serving Model Context Protocol (MCP) tools so the agent never directly interacts with sensitive credentials or unauthorized external endpoints.

## Goals

- Define the architecture for deploying independent reverse proxy configurations per agent sandbox.
- Spec the mechanism for proxy-hosted credentials, ensuring that sensitive tokens are never visible to the agent sandbox.
- Detail the MCP (Model Context Protocol) mediation layer served by the proxy for interacting with external services (such as GitHub or GCP).
- Provide a secure mechanism for pushing commits and opening Pull Requests upon task completion without exposing Git credentials to the agent.

## Non-Goals

- Specifying the basic proxying and TLS termination algorithms (covered by `factory-runtime-proxy` and `factory-runtime-proxy-tls`).
- Specifying general Kubernetes Pod lifecycle management (covered by `factory-operator`).

## Key Requirements

- **Strict Sandbox Isolation**: Sandboxes must have no direct external network access except through the designated reverse proxy.
- **Zero-Trust Credentials**: No sensitive API keys or write-tokens may be environment-configured or mounted within the agent sandbox container. All credentials must be stored on and used exclusively by the reverse proxy.
- **Independent Security Policies**: Each task/sandbox launched by the operator must have a distinct, granular security policy specifying allowed endpoints, verbs, and tools.
- **MCP Tool Mediation**: External system modifications (like GitHub API calls, cloud platform updates) must be routed through the Model Context Protocol (MCP) server running on the proxy, which applies permission checks before execution.

## Design

### 1. Multi-Tenant Proxy Configurations
The `factory operator` will manage the lifecycle of both the agent sandbox and its companion reverse proxy.
- **Sidecar or Local Gateway**: For each sandbox, the operator configures a dedicated reverse proxy instance (either as a sidecar inside the same Pod or as a dedicated, isolated Pod in the same namespace).
- **Independent Policies**: The operator generates a customized `ProxySpec` for each proxy instance based on the task description and requirements.
- **Network Isolation**: A Kubernetes `NetworkPolicy` strictly restricts egress from the sandbox Pod to only the proxy Pod/container IP and the proxy port.

### 2. Direct LLM Egress Filtering
- The proxy allows direct, transparent HTTPS forwarding for LLM provider API endpoints (e.g., `https://generativelanguage.googleapis.com`).
- The operator configures these endpoints in the proxy's `allowedURLs` list.
- All other direct outbound HTTPS connections from the sandbox are dropped or rejected with `403 Forbidden` by the proxy.

### 3. Credential Hosting and Header Injection
To perform work, the proxy dynamically injects authentication tokens into the HTTP headers of allowed requests.
- **Secret Mounting**: Secrets (such as GitHub PATs, GCP service account keys) are mounted as Kubernetes secrets directly to the proxy container.
- **No Agent Visibility**: The agent sandbox does not have these secrets mounted.
- **Placeholder Injection**: The agent uses placeholder headers (e.g., `Authorization: Bearer GITHUB_TOKEN_PLACEHOLDER`). The proxy interceptor detects the placeholder, reads the token from its local secret file, and replaces it on the fly before forwarding upstream.

### 4. MCP Tool Mediation
For richer operations that cannot be handled via simple HTTPS forwarding (e.g., complex queries, multi-step actions), the proxy runs an MCP (Model Context Protocol) server.
- **SSE or HTTP Protocol**: The proxy's MCP server exposes a local port reachable by the agent sandbox. The agent communicates using JSON-RPC over Server-Sent Events (SSE) or HTTP POST.
- **Secure Action Processing**: When the agent requests an action (e.g., `list_issues`, `read_file_from_github`), the proxy MCP server:
  1. Validates that the action is allowed under the current sandbox's security policy.
  2. Executes the request against the external API (e.g., GitHub API) using its locally hosted credentials.
  3. Sanitizes the response (removing metadata, internal IPs, or leak risks) and returns it to the agent.

### 5. Secure Pull Request Pushing
When a task is finished, the agent needs a way to submit its changes as a Pull Request.
- **Option A (MCP Git Tool)**: The proxy MCP server exposes a `push_pull_request` tool. The agent sends the patch or commit details to the MCP server. The proxy commits, signs, and pushes the branch to GitHub using its hosted SSH or HTTPS keys, then submits the PR.
- **Option B (Proxy-Mediated Git Egress)**: If the agent runs `git push` directly, the proxy permits Git over HTTPS/SSH traffic only to the specific target repository URL, and injects the credential headers.
- **Option A is preferred** because it provides maximum auditability and prevents the agent from running arbitrary Git push commands to unauthorized repositories or branches.

## Examples

### Security Configuration per Sandbox
Below is an example of an `OperatorConfig` setting up a sandbox and its proxy configuration, defining the policy and hosted credentials:

```yaml
apiVersion: factory.ai.gke.io/v1alpha1
kind: SandboxPolicy
metadata:
  name: task-12345-policy
spec:
  sandboxId: task-12345
  allowedLLMEgress:
    - https://generativelanguage.googleapis.com/*
  mcpTools:
    - name: github-issues
      allowedRepos:
        - ai-on-gke/ai-factory
      permissions:
        - read-only
    - name: github-pr
      allowedRepos:
        - ai-on-gke/ai-factory
      permissions:
        - read-write
  secrets:
    - name: github-token
      secretName: factory-github-token-secret
      mountPath: /var/run/secrets/github
```

## Tests

- **Credential Isolation Tests**: Verify that the agent container has absolutely no access to the secret mount paths or environment variables of the proxy.
- **Proxy Egress Rules Tests**: Verify that requests to non-LLM endpoints without going through MCP or allowed URL rules are strictly blocked.
- **MCP Tool Security Tests**: Validate that the MCP server rejects commands targeting unauthorized repositories or executing unauthorized actions (e.g., attempting a write action when only read-only permission is granted).
- **Secure PR Integration Tests**: Mock a GitHub server and verify that an agent can successfully trigger a PR push using the proxy's MCP tool, and that the proxy correctly executes the action using the hosted credentials.
