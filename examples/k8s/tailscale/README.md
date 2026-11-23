# Tailscale on the OKE cluster

Installed by ArgoCD, not OpenTofu: tofu stops at the cluster boundary.

| File | What |
|---|---|
| `tailnet-policy.hujson` | Tags and grants to merge into your tailnet policy |
| `operator-oauth.secret.example.yaml` | Shape of the OAuth secret (encrypt with SOPS / use External Secrets) |
| `argocd-application.yaml` | Operator Helm chart, API server proxy in auth mode |
| `rbac.yaml` | Maps the tailnet grant to cluster-admin |
| `service-tailnet.yaml` | Exposing a Service to the tailnet (no OCI load balancer) |

## Order

1. Tailscale admin console: merge `tailnet-policy.hujson`, then create an OAuth
   client with **Devices: Core** and **Auth Keys** write scopes, tagged `tag:k8s-operator`.
2. With your IP still in `api_allowed_cidrs`: create the `tailscale` namespace
   and the `operator-oauth` secret, then apply `rbac.yaml` and `argocd-application.yaml`.
3. `tailscale configure kubeconfig oke-free-operator`, then `kubectl get nodes` over the tailnet.
4. In your consumer repo's `config/settings.tfvars`, set `cluster.api_allowed_cidrs = []`
   (keep `enable_tailscale = true`), and merge it through a PR. The public API endpoint
   now admits nobody.

Break-glass if Tailscale is down: put your /32 back in `api_allowed_cidrs`,
apply, and use `make kubeconfig` in your consumer repo. That works because tofu never needed the Kubernetes API.
