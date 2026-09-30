# Contributing Guide

This guide explains how to contribute to the home-ops repository, whether adding applications, fixing bugs, or improving documentation.

## Prerequisites

### Local Setup
1. Clone the repository
2. Install tools via mise:
   ```bash
   mise install
   ```
3. Source environment variables:
   ```bash
   eval "$(mise activate)"
   ```

### Required Knowledge
- Kubernetes basics (Pods, Services, Deployments, Namespaces, etc.)
- Kustomize (overlays, components, patches)
- Helm (charts, values, releases)
- YAML syntax
- Git workflows
- Flux CD concepts (Kustomization, HelmRelease)

## Repository Standards

### Branch Naming
- Feature: `feature/short-description`
- Bug fix: `fix/issue-number-or-description`
- Documentation: `docs/what-changed`
- Renovate updates: Renovate auto-creates branches (no naming needed)

### Commit Messages
Follow conventional commits for consistency:
- `feat:` — New feature
- `fix:` — Bug fix
- `docs:` — Documentation
- `refactor:` — Code restructuring (no functional change)
- `test:` — Tests
- `chore:` — Maintenance, dependency updates
- `ci:` — CI/CD configuration

**Examples**:
```
feat: add grafana dashboard for nginx metrics
fix: correct postgres secret reference in deployment
docs: update README with DNS setup instructions
chore: update kube-prometheus-stack to 65.0.0
```

Renovate uses semantic commits automatically (configured in `.renovate/semanticCommits.json5`).

### Pull Request Guidelines

1. **Scope**: Keep PRs focused on a single concern
   - ✅ Add one application namespace
   - ❌ Add application + update infrastructure + fix documentation

2. **Title**: Clear, descriptive, matches commit message format
   - ✅ `feat: add Vaultwarden application`
   - ❌ `fixed stuff`

3. **Description**: Explain what changed and why
   - What problem does this solve?
   - How does it work?
   - Any breaking changes or manual steps?

4. **Testing**: Validate before pushing
   - Run kustomize validation
   - Check manifests with kubeconform
   - Test SOPS encryption if using secrets

## Adding a New Application

### Step 1: Create Namespace Structure

If the namespace doesn't exist:
```bash
mkdir -p kubernetes/apps/{namespace}/{app}/app
```

### Step 2: Create Namespace Resources

Use the namespace component for consistency:

**kubernetes/apps/{namespace}/kustomization.yaml**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: {namespace}

resources:
  - namespace
  - ./ks.yaml

components:
  - ../../components/namespace
  - ../../components/sops  # If using secrets
```

**kubernetes/apps/{namespace}/namespace/kustomization.yaml**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../../components/namespace
```

### Step 3: Create Application Resources

**kubernetes/apps/{namespace}/{app}/app/kustomization.yaml**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: {namespace}

resources:
  - helmrelease.yaml
  # OR use raw manifests:
  # - deployment.yaml
  # - service.yaml
```

**kubernetes/apps/{namespace}/{app}/app/helmrelease.yaml** (using Helm):
```yaml
apiVersion: helm.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: {app}
  namespace: {namespace}
spec:
  interval: 5m
  chart:
    spec:
      chart: {chart-name}
      version: {version}
      sourceRef:
        kind: HelmRepository
        name: {repo-name}
        namespace: flux-system
  values:
    # Insert chart values here
    # Reference: https://artifacthub.io/packages/helm/{repo}/{chart}
```

Or use raw Kubernetes manifests in `deployment.yaml`, `service.yaml`, etc.

### Step 4: Register with Flux

**kubernetes/apps/{namespace}/ks.yaml**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
metadata:
  name: {app}
  namespace: flux-system
spec:
  interval: 5m
  path: ./kubernetes/apps/{namespace}/{app}/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: home
    namespace: flux-system
  dependsOn:
    - name: namespace
  # Add health checks for critical apps:
  healthChecks:
    - apiVersion: v1
      kind: Deployment
      name: {app}
      namespace: {namespace}
```

Add reference to top-level **kubernetes/apps/{namespace}/kustomization.yaml**:
```yaml
resources:
  - namespace
  - {app}/ks.yaml  # Add this line
```

### Step 5: Add Secrets (if needed)

If the application requires secrets (passwords, API keys, etc.):

**kubernetes/apps/{namespace}/{app}/secret.sops.yaml**:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: {app}-secrets
  namespace: {namespace}
type: Opaque
stringData:
  username: my-user
  password: my-password
```

Encrypt with SOPS:
```bash
sops -e -i kubernetes/apps/{namespace}/{app}/secret.sops.yaml
```

Add to `kustomization.yaml`:
```yaml
resources:
  - helmrelease.yaml
  - secret.sops.yaml
```

### Step 6: Validate

```bash
# Validate kustomization
kustomize build kubernetes/apps/{namespace}/{app}/app --enable-helm

# Validate with kubeconform
kustomize build kubernetes/apps/{namespace}/ --enable-helm | kubeconform -summary

# Check SOPS encryption (if applicable)
sops -d kubernetes/apps/{namespace}/{app}/secret.sops.yaml
```

### Step 7: Push and Create PR

```bash
git add kubernetes/apps/{namespace}/
git commit -m "feat: add {app} application"
git push origin feature/add-{app}
# Create PR on GitHub
```

## Updating Existing Applications

### Manual Update
1. Edit `app/helmrelease.yaml` (update `version:` or `values:`)
2. Or edit `app/deployment.yaml` for raw manifests
3. Validate: `kustomize build kubernetes/apps/{namespace}/{app}/app --enable-helm`
4. Commit and push
5. Flux auto-syncs within reconciliation interval

### Automated Update (Renovate)
Renovate automatically detects updates to:
- Helm chart versions
- Docker image versions (with pinned digests)
- Kubernetes API versions
- Tool versions

Configuration in `.renovate/` controls auto-merge behavior.

## Adding Reusable Components

If creating a new reusable component (shared across namespaces):

1. Create **kubernetes/components/{component-name}/**
2. Add `kustomization.yaml` with reusable resources
3. Create **README.md** documenting usage
4. Reference from namespace `kustomization.yaml`:
   ```yaml
   components:
     - ../../components/{component-name}
   ```

## Handling Secrets

### Never commit plaintext secrets
- ✅ Encrypt with SOPS: `sops -e -i secret.sops.yaml`
- ❌ Don't commit plaintext credentials

### File naming convention
- `secret.sops.yaml` — Encrypted secret
- `secret-original.yaml` — Never commit (use .gitignore if needed)

### Testing encrypted files
```bash
# Verify encryption
sops -d kubernetes/apps/namespace/secret.sops.yaml

# Decrypt for local testing (be careful!)
sops -d kubernetes/apps/namespace/secret.sops.yaml > /tmp/secret.yaml
# Use it locally, then delete: rm /tmp/secret.yaml
```

## Running Tests Locally

### Validate Kustomizations
```bash
# Validate all apps
kustomize build kubernetes/ --enable-helm | kubeconform -summary -output json

# Validate specific namespace
kustomize build kubernetes/apps/{namespace}/ --enable-helm | kubeconform -summary
```

### Lint YAML
```bash
# Using yamlfmt (configured in .yamlfmt.yaml)
yamlfmt -d kubernetes/
```

### Validate Talos Configuration (if modifying Talos)
```bash
just talos validate-config <node-ip>
```

## Code Review Process

1. Create PR with descriptive title and description
2. Automated checks run (lint, validate, etc.)
3. Maintainer reviews changes
4. Address feedback (if any)
5. PR merged to main
6. Flux auto-syncs to cluster

### What Reviewers Look For
- Kubernetes best practices (labels, namespaces, RBAC)
- Security (no plaintext secrets, least privilege)
- Consistency (matches repo patterns and conventions)
- Documentation (README for new components, comments for non-obvious code)
- Testing (validated manifests, no breaking changes)

## Troubleshooting

### Kustomize Build Fails
```bash
# Validate YAML syntax
yamlfmt -d kubernetes/

# Debug kustomization
kustomize build kubernetes/apps/{namespace}/ --enable-helm

# Check component references
kustomize build --enable-helm
```

### SOPS Decryption Fails
```bash
# Check age key
ls -la age.key

# Verify SOPS config
cat .sops.yaml

# Try manual decryption
sops -d kubernetes/apps/{namespace}/secret.sops.yaml
```

### Flux Not Applying Changes
```bash
# Check Flux logs
flux logs -f --all-namespaces

# Check Kustomization status
kubectl get kustomization -A

# Check HelmRelease status
kubectl get helmrelease -A
```

## Documentation

### Update docs when:
- Adding new application types or patterns
- Changing deployment procedures
- Documenting operational guides
- Recording decisions or lessons learned

### Where to add docs:
- **docs/STRUCTURE.md** — Repository structure
- **kubernetes/components/{comp}/README.md** — Component usage
- **kubernetes/apps/{namespace}/{app}/README.md** — Application-specific notes
- **docs/notes/** — Operational runbooks

## Questions?

- Check [CLAUDE.md](../CLAUDE.md) for project overview
- Check [ARCHITECTURE.md](../ARCHITECTURE.md) for system design
- Check existing namespaces for examples
- Check Kubernetes @ Home Discord for community support

---

**Thank you for contributing!** 🚀
