# Architecture

## Overview

This project deploys a full homelab stack on a single NixOS machine using K3s (lightweight Kubernetes). Everything is declared in Nix and applied via systemd oneshot services on boot.

## System Layers

```
NixOS (base OS)
  -> K3s (lightweight Kubernetes)
    -> Helm charts + raw manifests (deployed by systemd services)
      -> Pods running all homelab services
```

## Boot Ordering (systemd tiers)

Services start in a defined order to avoid resource contention:

1. **k3s-infrastructure** - K3s, MetalLB, Traefik, cert-manager, NFS storage
2. **k3s-storage** - PVCs, shared-data setup
3. **k3s-core** - Authentik, monitoring, Vaultwarden, dashboard
4. **k3s-media** - Jellyfin, arr-stack, Bazarr, Lidarr, Bookshelf, Kavita
5. **k3s-extras** - Syncthing, Immich, Uptime Kuma, Kiwix, arr connections, OIDC config

Each tier is a systemd target. Services declare `wantedBy` and `before` on their tier target.

## Directory Structure

```
modules/kubernetes/
  default.nix          - Orchestrator with conditional imports
  lib.nix              - Shared helpers (wait, deploy, ingress, PVC, etc.)
  systemd-targets.nix  - Tier ordering targets
  infrastructure/      - K3s, MetalLB, Traefik, cert-manager, NFS
  auth/                - Authentik, SSO, LDAP
  cloud/               - Nextcloud, Vaultwarden, Immich, Syncthing
  media/               - Jellyfin, arr-stack, Bazarr, Jellyseerr, etc.
  monitoring/          - Grafana, Prometheus, Loki, Uptime Kuma
  knowledge/           - Kiwix (offline Wikipedia, iFixit)
  dashboard/           - Homarr
  backup/              - Restic backup to NAS
```

## Idempotency

Every setup service uses a marker file pattern:
1. Check if `/var/lib/<service>-setup-done` exists
2. If yes, exit immediately
3. If no, run setup, then create the marker

To re-run a service: `sudo rm /var/lib/<service>-setup-done && sudo systemctl restart <service>-setup`

## Storage

Two modes controlled by `config.nix`:

- **NFS** (`storage.useNFS = true`): Mounts from a NAS. Pods use hostPath PVs pointing to `/mnt/nas1`.
- **Local** (`storage.useNFS = false`): Uses `/var/lib/media-data` on the server.

Media services share a `shared-data` PVC following the TRaSH Guides folder structure:
```
/data/
  torrents/{movies,tv,music,books}
  media/{movies,tv,music,books}
```

## Authentication

- **SSO (Authentik OIDC)**: Jellyseerr, Jellyfin, Grafana, Nextcloud, Immich, Vaultwarden
- **Local auth**: arr-stack services (credentials stored in Vaultwarden)
- **No auth**: Prometheus, Alertmanager (local network only)

## Networking

- MetalLB assigns IPs from the configured pool
- Traefik handles HTTPS termination with a wildcard certificate
- cert-manager issues the wildcard via Cloudflare DNS challenge
- All services available at `<service>.<subdomain>.<domain>`
