# Dev image pull secret

Create once before pulling private GHCR images.

```bash
kubectl -n ecom-dev create secret docker-registry ecom-dev-ghcr \
  --docker-server=ghcr.io \
  --docker-username=just-vile \
  --docker-password=MY_GHCR_TOKEN
```

The dev overlay now injects `imagePullSecrets: [{ name: ecom-dev-ghcr }]` into all Deployments.
