# Services

## Infrastructure

| Service | Description | Namespace |
|---------|-------------|-----------|
| K3s | Lightweight Kubernetes | system |
| MetalLB | Bare-metal load balancer | metallb-system |
| Traefik | Ingress controller + HTTPS | traefik-system |
| cert-manager | Wildcard TLS certificates | cert-manager |

## Authentication

| Service | Description | URL Pattern |
|---------|-------------|-------------|
| Authentik | SSO/OIDC provider | `auth.<subdomain>.<domain>` |

## Cloud

| Service | Description | URL Pattern |
|---------|-------------|-------------|
| Nextcloud | File sync and sharing | `cloud.<subdomain>.<domain>` |
| Vaultwarden | Password manager | `vault.<subdomain>.<domain>` |
| Immich | Photo management | `photos.<subdomain>.<domain>` |
| Syncthing | File synchronization | `sync.<subdomain>.<domain>` |

## Media

| Service | Description | URL Pattern |
|---------|-------------|-------------|
| Jellyfin | Media server | `jellyfin.<subdomain>.<domain>` |
| Jellyseerr | Media requests | `requests.<subdomain>.<domain>` |
| Sonarr | TV show management | `sonarr.<subdomain>.<domain>` |
| Radarr | Movie management | `radarr.<subdomain>.<domain>` |
| Lidarr | Music management | `lidarr.<subdomain>.<domain>` |
| Bazarr | Subtitle management | `bazarr.<subdomain>.<domain>` |
| Prowlarr | Indexer management | `prowlarr.<subdomain>.<domain>` |
| qBittorrent | Torrent client | `qbit.<subdomain>.<domain>` |
| FlareSolverr | Cloudflare bypass | internal only |
| Recyclarr | TRaSH Guides sync | CronJob |

## Monitoring

| Service | Description | URL Pattern |
|---------|-------------|-------------|
| Grafana | Dashboards | `grafana.<subdomain>.<domain>` |
| Prometheus | Metrics collection | `prometheus.<subdomain>.<domain>` |
| Loki | Log aggregation | internal (via Grafana) |

## Knowledge

| Service | Description | URL Pattern |
|---------|-------------|-------------|
| Kiwix | Offline Wikipedia + iFixit | `wiki.<subdomain>.<domain>` |

## Dashboard

| Service | Description | URL Pattern |
|---------|-------------|-------------|
| Homepage | Application dashboard. Cards show pod state and resources, widgets show service data, and stopped services sit in a collapsed group. | `home.<subdomain>.<domain>` |
| Traefik API | Read-only Traefik API for the dashboard widget, behind basic auth (secret `traefik-api-credentials`). | `traefik-api.<subdomain>.<domain>` |

## Backup

| Service | Description |
|---------|-------------|
| Restic | Encrypted backups to NAS |

## Enabling/Disabling Services

Toggle services in `config.nix`:

```nix
services = {
  authentik = true;    # SSO provider
  vaultwarden = true;  # Password manager
  nextcloud = false;   # File sharing
  monitoring = true;   # Grafana + Prometheus + Loki
  media = false;       # Full media stack
  immich = false;      # Photo management
  syncthing = false;   # File sync
  dashboard = true;    # Homepage
  kiwix = false;       # Offline knowledge (Wikipedia, iFixit)
};
```

Setting `media = true` enables all media services (Jellyfin, arr-stack, Bazarr, etc.).
