{
  certificates = {
    provider = "acme";
  };

  services = {
    authentik = false;
    vaultwarden = false;
    nextcloud = false;
    media = false;
    immich = false;
    syncthing = false;
    dashboard = false;
    kiwix = false;
    openstreetmap = false;
    switchboard = false;
    paperless = false;
    stirling-pdf = false;
  };

  nas = { };

  authentik = {
    ldap.enable = false;
    bootstrapUsers = { };
  };

  jellyfin = { };
  qbittorrent = { };

  opensubtitles = {
    username = "";
  };

  backup = {
    localPath = "/var/lib/backup/repo";
    extraPaths = [ ];
  };
}
