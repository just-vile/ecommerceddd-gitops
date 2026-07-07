# Rollback Runbook

## Rollback an application deployment

```bash
# 1. Identify the last known-good commit in EcommerceDDD-gitops
git log --oneline apps/environments/dev/values/<service>.yaml

# 2. Revert the image tag bump commit
git revert <bad-commit-sha>
git push origin main

# 3. Argo CD auto-syncs within ~3 minutes (selfHeal: true)
# Monitor:
kubectl get applications -n argocd apps-dev -w
```

## Emergency: pause Argo CD auto-sync

```bash
# Pause auto-sync for a specific app (e.g. during an incident)
argocd app set apps-dev --sync-policy none

# Resume auto-sync when ready
argocd app set apps-dev --sync-policy automated
```

## Rollback a platform component

```bash
git revert <bad-platform-commit>
git push origin main
# Argo CD reconciles automatically
```

## Rollback CNPG (Postgres)

See [cnpg-recovery.md](cnpg-recovery.md).
