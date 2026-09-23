# Updating with Helm

## Overview

After you've made code changes and GitHub Actions has built new Docker images, you need to update your Helm deployment to use the new images.

## Prerequisites

- Helm 3.x installed (already in your Codespace)
- Access to your Kubernetes cluster
- New Docker images built and available in GHCR

## Update Process

### 1. Identify New Image Tags

After GitHub Actions builds your images, identify the new image tag:

**Option A: Use `latest` tag**
```bash
# Images are tagged with 'latest' automatically
# Format: ghcr.io/{your-username}/vegasapp-{service}:latest
```

**Option B: Use specific commit SHA**
```bash
# Check GitHub Actions for the commit SHA
# Format: ghcr.io/{your-username}/vegasapp-{service}:{commit-sha}
```

### 2. Update Helm Values

Edit the Helm values file or use `--set` flags:

**Method 1: Edit values.yaml**

```bash
# Edit the values file
vim helm/vegas-casino/values.yaml
```

Update the image registry and tag:

```yaml
global:
  imageRegistry: ghcr.io/your-username  # Your GitHub username
  imageTag: "latest"  # or specific commit SHA

# Or per-service
frontend:
  image:
    repository: ghcr.io/your-username/vegasapp-frontend
    tag: "latest"
```

**Method 2: Use --set flags**

```bash
helm upgrade vegas-casino ./helm/vegas-casino \
  --set global.imageRegistry=ghcr.io/your-username \
  --set global.imageTag=latest \
  --namespace vegas-casino
```

### 3. Upgrade Helm Release

```bash
# Upgrade the release
helm upgrade vegas-casino ./helm/vegas-casino \
  --namespace vegas-casino \
  -f helm/vegas-casino/values.yaml

# Or with custom values
helm upgrade vegas-casino ./helm/vegas-casino \
  --namespace vegas-casino \
  --set global.imageRegistry=ghcr.io/your-username \
  --set global.imageTag=latest
```

### 4. Verify Deployment

```bash
# Check rollout status
kubectl rollout status deployment/vegas-casino-frontend -n vegas-casino

# View pods
kubectl get pods -n vegas-casino

# Check pod images
kubectl get pods -n vegas-casino -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}'
```

## Updating Specific Services

### Update Frontend Only

```bash
helm upgrade vegas-casino ./helm/vegas-casino \
  --namespace vegas-casino \
  --set frontend.image.repository=ghcr.io/your-username/vegasapp-frontend \
  --set frontend.image.tag=latest
```

### Update Game Service

```bash
# Example: Update slots service
helm upgrade vegas-casino ./helm/vegas-casino \
  --namespace vegas-casino \
  --set slots.image.repository=ghcr.io/your-username/vegasapp-slots \
  --set slots.image.tag=latest
```

### Update Multiple Services

```bash
helm upgrade vegas-casino ./helm/vegas-casino \
  --namespace vegas-casino \
  --set global.imageRegistry=ghcr.io/your-username \
  --set global.imageTag=latest \
  --set slots.image.tag=abc1234 \
  --set roulette.image.tag=def5678
```

## Image Pull Secrets

If your images are private, configure image pull secrets:

### 1. Create Secret

```bash
# Create GitHub personal access token with read:packages permission
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=your-username \
  --docker-password=your-token \
  --namespace vegas-casino
```

### 2. Update Helm Values

```yaml
global:
  imagePullSecrets:
    - name: ghcr-secret
```

### 3. Upgrade

```bash
helm upgrade vegas-casino ./helm/vegas-casino \
  --namespace vegas-casino \
  --set global.imagePullSecrets[0].name=ghcr-secret
```

## Rollback

If something goes wrong, rollback to previous version:

```bash
# View release history
helm history vegas-casino -n vegas-casino

# Rollback to previous version
helm rollback vegas-casino -n vegas-casino

# Rollback to specific revision
helm rollback vegas-casino 3 -n vegas-casino
```

## Troubleshooting

### Image Pull Errors

```bash
# Check image exists
docker pull ghcr.io/your-username/vegasapp-frontend:latest

# Verify image pull secrets
kubectl get secret -n vegas-casino

# Check pod events
kubectl describe pod <pod-name> -n vegas-casino
```

### Pods Not Updating

```bash
# Force pod recreation
kubectl delete pod -l app=vegas-casino-frontend -n vegas-casino

# Or restart deployment
kubectl rollout restart deployment/vegas-casino-frontend -n vegas-casino
```

### Wrong Image Version

```bash
# Check current image
kubectl get deployment vegas-casino-frontend -n vegas-casino \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Update with correct tag
helm upgrade vegas-casino ./helm/vegas-casino \
  --namespace vegas-casino \
  --set frontend.image.tag=correct-tag
```

## Best Practices

1. **Use Specific Tags**: Instead of `latest`, use commit SHA for reproducibility
2. **Test First**: Test changes in a development namespace before production
3. **Gradual Rollout**: Update services one at a time to isolate issues
4. **Monitor**: Watch pod logs and metrics after updates
5. **Keep History**: Don't delete old Helm releases (for rollback)

## Example Workflow

```bash
# 1. Make code changes and push
git add services/slots/slots-service.js
git commit -m "Improve instrumentation"
git push origin main

# 2. Wait for GitHub Actions to build (check Actions tab)

# 3. Update Helm with new image
helm upgrade vegas-casino ./helm/vegas-casino \
  --namespace vegas-casino \
  --set slots.image.tag=latest \
  --reuse-values

# 4. Verify deployment
kubectl rollout status deployment/vegas-casino-slots -n vegas-casino

# 5. Test the changes
kubectl port-forward -n vegas-casino svc/vegas-casino-frontend 3000:3000
# Open http://localhost:3000 and test
```

## Next Steps

- [Source Code Locations](source-code.md): Find where to make changes
- [GitHub Actions Workflow](github-actions.md): Understand image building
- [Feature Flags Guide](feature-flags.md): Learn about feature flags
