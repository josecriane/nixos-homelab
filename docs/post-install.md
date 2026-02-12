# Post-Install Manual Steps

After the initial deployment completes, some services need manual configuration.

## Jellyseerr Setup

Visit `https://requests.<subdomain>.<domain>` and:
1. Select Jellyfin as media server
2. Enter Jellyfin connection details (hostname: `jellyfin.media.svc.cluster.local`, port: 8096)
3. Create an admin account using your Jellyfin credentials
4. Enable media libraries
5. Click Initialize

## Jellyfin SSO Plugin

1. Go to Jellyfin Admin > Plugins > Catalog
2. Install "SSO Authentication" plugin
3. Restart Jellyfin
4. Configure the SSO provider in Plugin Settings with your Authentik OIDC details

## Bazarr Language Profile

1. Go to Bazarr Settings > Languages
2. Enable your preferred languages
3. Create a language profile
4. Set it as default for series and movies
5. Go to Settings > Providers and add subtitle providers (OpenSubtitles.com requires an API key)

## Kavita OIDC

Kavita v0.8+ manages OIDC through the admin UI:
1. Log in to Kavita as admin
2. Go to Settings > Authentication
3. Add your Authentik OIDC provider

## Quality Profile Tuning

Recyclarr syncs TRaSH Guides profiles automatically. For fine-tuning:
- Sonarr: Settings > Profiles
- Radarr: Settings > Profiles
- See [TRaSH Guides](https://trash-guides.info/) for recommendations

## Media Import

To import existing media files:
- Sonarr: Library > Import (select `/data/media/tv`)
- Radarr: Library > Import (select `/data/media/movies`)
- Lidarr: Library > Import (select `/data/media/music`)

## Vaultwarden

Register your first user at `https://vault.<subdomain>.<domain>/#/register`.
Create an organization called "Homelab Admin" and add service credentials.
