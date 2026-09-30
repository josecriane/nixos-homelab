{
  k8s,
  config,
  lib,
  pkgs,
  ...
}:

let
  arr = import ./arr-lib.nix { inherit lib; };
  markerFile = "/var/lib/arr-naming-setup-done";

  filters = {
    sonarrNaming = ''
      .renameEpisodes = true |
      .standardEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Custom Formats}][{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}" |
      .dailyEpisodeFormat = "{Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Custom Formats}][{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}" |
      .animeEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle} [{Custom Formats}][{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{MediaInfo AudioLanguages}{[MediaInfo VideoDynamicRangeType]}[{Mediainfo VideoCodec} {MediaInfo VideoBitDepth}bit]{-Release Group}" |
      .seriesFolderFormat = "{Series TitleYear}" |
      .seasonFolderFormat = "Season {season:00}"
    '';
    sonarrMgmt = ''
      .autoRenameFolders = true |
      .importExtraFiles = true |
      .extraFileExtensions = "srt,sub,idx" |
      .copyUsingHardlinks = true |
      .autoUnmonitorPreviouslyDownloadedEpisodes = true |
      .downloadPropersAndRepacks = "doNotPrefer"
    '';
    radarrNaming = ''
      .renameMovies = true |
      .movieFolderFormat = "{Movie CleanTitle} ({Release Year})" |
      .standardMovieFormat = "{Movie CleanTitle} {(Release Year)} {Edition Tags} [{Custom Formats}][{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}"
    '';
    radarrMgmt = ''
      .autoRenameFolders = true |
      .importExtraFiles = true |
      .extraFileExtensions = "srt,sub,idx" |
      .copyUsingHardlinks = true |
      .minimumFreeSpaceWhenImporting = 10000 |
      .downloadPropersAndRepacks = "doNotPrefer"
    '';
  };

  targets = [
    {
      app = "sonarr";
      naming = "sonarrNaming";
      mgmt = "sonarrMgmt";
    }
    {
      app = "sonarr-es";
      naming = "sonarrNaming";
      mgmt = "sonarrMgmt";
    }
    {
      app = "radarr";
      naming = "radarrNaming";
      mgmt = "radarrMgmt";
    }
    {
      app = "radarr-es";
      naming = "radarrNaming";
      mgmt = "radarrMgmt";
    }
  ];

  filterVars = lib.concatStringsSep "\n        " (
    lib.mapAttrsToList (name: body: "FILTER_${lib.toUpper name}=${lib.escapeShellArg body}") filters
  );

  calls =
    target:
    "arr_patch ${target.app} config/naming \"\$FILTER_${lib.toUpper target.naming}\" naming\n"
    + "        arr_patch ${target.app} config/mediamanagement \"\$FILTER_${lib.toUpper target.mgmt}\" \"media management\"";
in
{
  systemd.services.arr-naming-setup = {
    description = "Configure TRaSH Guides naming and media management for Sonarr/Radarr";
    after = [
      "k3s-apps.target"
      "arr-credentials-setup.service"
      "recyclarr-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
    wants = [
      "arr-credentials-setup.service"
      "recyclarr-setup.service"
    ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "arr-naming-setup" ''
        ${k8s.libShSource}
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        set +e

        setup_preamble "${markerFile}" "Naming and media management"
        wait_for_k3s

        ${arr.helpers}

        ${filterVars}

        echo "Configuring naming and media management (TRaSH Guides)..."
        ${lib.concatMapStringsSep "\n        " calls targets}

        echo ""
        echo "=== Naming and media management configured ==="

        create_marker "${markerFile}"
      '';
    };
  };
}
