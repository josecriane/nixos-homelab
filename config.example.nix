{
  # Cluster nodes (keyed by hostname)
  nodes = {
    server1 = {
      ip = "192.168.1.100";
      role = "server";
      bootstrap = true;
    };
  };

  gateway = "192.168.1.1";
  nameservers = [
    "1.1.1.1"
    "8.8.8.8"
  ];
  useWifi = false;
  wifiSSID = "";
  domain = "example.com";
  subdomain = "home";
  adminUser = "admin";
  adminSSHKeys = [
    # (builtins.readFile ./keys/admin.pub)
  ];
  puid = 1000;
  pgid = 1000;
  acmeEmail = "you@example.com";
  metallbPoolStart = "192.168.1.200";
  metallbPoolEnd = "192.168.1.254";
  traefikIP = "192.168.1.200";
  timezone = "UTC";

  services = {
    authentik = true;
    vaultwarden = true;
    nextcloud = false;
    monitoring = true;
    media = false;
    immich = false;
    syncthing = false;
    dashboard = true;
    kiwix = false;
    openstreetmap = false;
    # Upstream toggles (from nixos-k8s): browser-based K8s workload control
    # panel and the Traefik dashboard IngressRoute.
    switchboard = false;
    traefikDashboard = false;
  };

  vaultwarden = {
    # Mirrors the generated service credentials into a Vaultwarden
    # collection. Turn it off if the bitwarden-cli in your nixpkgs is
    # newer than the API your Vaultwarden release implements.
    # sync = { enable = true; };
    # Services declared outside this repository can join the sync. Each entry
    # names the K8s Secret and which keys hold the username, password and URL;
    # noteKeys are copied into the item notes and unit is the setup service to
    # wait for.
    # sync.extraServices = [
    #   {
    #     name = "Suwayomi";
    #     namespace = "media";
    #     secret = "suwayomi-credentials";
    #     userKey = "AUTH_USERNAME";
    #     passwordKey = "AUTH_PASSWORD";
    #     urlKey = "URL";
    #     unit = "suwayomi-setup.service";
    #   }
    # ];
  };

  authentik = {
    adminEmail = "admin@home.example.com";
    # ldap = { enable = false; };

    # Google as a login source. Users log in with their Google account and
    # authentik links it to the existing user with the same email. Create the
    # OAuth client in Google Cloud with the redirect URI
    # https://auth.<subdomain>.<domain>/source/oauth/callback/google/ and store
    # its secret under secrets/authentik-google-client-secret.age.
    # google = {
    #   enable = true;
    #   clientId = "1234567890-abc.apps.googleusercontent.com";
    #   allowEnrollment = false;
    # };

    # Declarative bootstrap users. Each user is created via the Authentik API
    # with the password read from agenix. The key name is the username. Store
    # each password under secrets/<passwordSecret>.age.
    # bootstrapUsers = {
    #   jose = {
    #     email = "jose@example.com";
    #     name = "Jose";
    #     groups = [ "admins" "media-admins" "media-users" "monitoring" ];
    #     passwordSecret = "authentik-user-jose-password";
    #   };
    # };
  };

  # NAS integration (or use setup.sh to configure interactively)
  nas = {
    # nas1 = {
    #   enabled = true;
    #   ip = "192.168.1.50";
    #   hostname = "nas1";
    #   role = "media";
    #   nfsExports = {
    #     nfsPath = "/";
    #     data = "/mnt/storage";
    #     media = "/mnt/storage/media";
    #     downloads = "/mnt/storage/downloads";
    #   };
    #   cockpitPort = 9090;
    #   fileBrowserPort = 8080;
    #   description = "Main NAS";
    # };
    # nas2 = {
    #   enabled = true;
    #   ip = "192.168.1.51";
    #   hostname = "nas2";
    #   role = "media";
    #   nfsExports = {
    #     nfsPath = "/";
    #   };
    #   # TRaSH paths stored on this NAS. Pods see them under /data/<hostname>/
    #   mediaPaths = [ "media/books" "media/music" "torrents/books" "torrents/music" "backups" ];
    #   # Cloud storage paths (NAS-backed PVs for cloud services, stored on specific disk)
    #   cloudPaths = {
    #     nextcloud = "cloud/nextcloud";
    #     immich = "cloud/immich";
    #     kiwix = "kiwix";
    #     openstreetmap = "maps";
    #   };
    #   cockpitPort = 9090;
    #   fileBrowserPort = 8080;
    #   description = "Secondary NAS";
    # };
  };
  storage = {
    useNFS = false;
    # Longhorn distributed block storage (optional)
    # longhorn = {
    #   enable = true;
    #   replicaCount = 2;
    #   defaultStorageClass = false;
    # };
  };
  certificates = {
    restoreFromBackup = false;
  };

  # Monitoring ingress auth. Prometheus/Alertmanager have no built-in auth,
  # so their ingresses are only created when middlewares are set.
  # Grafana self-auths (OIDC via Authentik), so its middlewares default to [].
  monitoring = {
    prometheus.middlewares = [
      {
        name = "forward-auth";
        namespace = "traefik-system";
      }
    ];
    alertmanager.middlewares = [
      {
        name = "forward-auth";
        namespace = "traefik-system";
      }
    ];
  };

  # Prowlarr. Private indexers are added by hand in its UI; the public ones
  # listed here are created from their Cardigann definition file. Priorities
  # (1 highest, 50 lowest) only break ties between releases that score the
  # same, custom formats decide the rest. removedIndexers deletes indexers
  # whose definition disappeared upstream.
  prowlarr = {
    indexers = [
      {
        name = "Public Tracker";
        definition = "publictracker";
        flaresolverr = false;
      }
    ];
    removedIndexers = [ ];
    indexerPriorities = {
      "Private Tracker (API)" = 10;
      "Public Tracker" = 40;
    };
  };

  # OpenSubtitles.com (for Bazarr subtitle downloads)
  # Password is stored encrypted via agenix (secrets/opensubtitles-password.age)
  opensubtitles = {
    username = "";
  };
}
