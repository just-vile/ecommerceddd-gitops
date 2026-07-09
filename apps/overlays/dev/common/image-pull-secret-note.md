# Dev image pull secret

Create once before pulling private GHCR images.

```bash
kubectl -n ecom-dev create secret docker-registry ecom-dev-ghcr \
  --docker-server=ghcr.io \
  --docker-username=MY_USER \
  --docker-password=MY_GHCR_TOKEN
```

This repo intentionally does not enforce imagePullSecrets yet to avoid blocking first bring-up.
