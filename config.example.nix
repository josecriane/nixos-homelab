{
  serverName = "my-server";
  serverIP = "192.168.1.100";
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
  };

  authentik = {
    adminEmail = "admin@home.example.com";
    # ldap = { enable = false; };
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
    #   # Paths bind-mounted into /mnt/nas1/ so services see them transparently
    #   mediaPaths = [ "media/books" "media/music" "torrents/books" "torrents/music" "backups" ];
    #   # Cloud storage paths (NAS-backed PVs for cloud services, stored on specific disk)
    #   cloudPaths = {
    #     nextcloud = "cloud/nextcloud";
    #     immich = "cloud/immich";
    #     kiwix = "kiwix";
    #   };
    #   cockpitPort = 9090;
    #   fileBrowserPort = 8080;
    #   description = "Secondary NAS";
    # };
  };
  storage = {
    useNFS = false;
  };
  certificates = {
    restoreFromBackup = false;
  };

  # OpenSubtitles.com (for Bazarr subtitle downloads)
  # Password is stored encrypted via agenix (secrets/opensubtitles-password.age)
  opensubtitles = {
    username = "";
  };
}
