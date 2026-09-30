{
  k8s,
  lib,
  pkgs,
  ...
}:

let
  arr = import ./arr-lib.nix { inherit lib; };
  markerFile = "/var/lib/lidarr-config-setup-done";

  namingFilter = ''
    .renameTracks = true |
    .replaceIllegalCharacters = true |
    .standardTrackFormat = "{Album Title} {(Album Disambiguation)}/{Artist Name}_{Album Title}_{track:00}_{Track Title}" |
    .multiDiscTrackFormat = "{Album Title} {(Album Disambiguation)}/{Artist Name}_{Album Title}_{medium:00}-{track:00}_{Track Title}" |
    .artistFolderFormat = "{Artist Name}"
  '';

  mgmtFilter = ".copyUsingHardlinks = true";

  qualityDefsFilter = ''
    [.[] |
      if .quality.name == "FLAC" then
        .minSize = 0 | .preferredSize = 895 | .maxSize = 1400
      elif .quality.name == "FLAC 24bit" then
        .minSize = 0 | .preferredSize = 895 | .maxSize = 1495
      else . end
    ]
  '';

  customFormats = [
    {
      name = "Preferred Groups";
      specs = [
        { name = "DeVOiD"; }
        { name = "PERFECT"; }
        { name = "ENRiCH"; }
      ];
    }
    {
      name = "CD";
      specs = [ { name = "CD"; } ];
    }
    {
      name = "WEB";
      specs = [ { name = "WEB"; } ];
    }
    {
      name = "Lossless";
      specs = [ { name = "FLAC"; } ];
    }
    {
      name = "Vinyl";
      specs = [ { name = "Vinyl"; } ];
    }
  ];

  mkSpec = spec: {
    name = spec.name;
    implementation = "ReleaseTitleSpecification";
    negate = false;
    required = false;
    fields.value = spec.pattern or "\\b${spec.name}\\b";
  };

  mkCustomFormat = cf: {
    name = cf.name;
    includeCustomFormatWhenRenaming = false;
    specifications = map mkSpec cf.specs;
  };

  ensureFormat =
    cf:
    "arr_ensure lidarr customformat ${lib.escapeShellArg (builtins.toJSON (mkCustomFormat cf))} "
    + "${lib.escapeShellArg ''.[] | select(.name == "${cf.name}")''} ${lib.escapeShellArg "CF ${cf.name}"}";

  formatScores = [
    {
      name = "Preferred Groups";
      score = 10;
    }
    {
      name = "CD";
      score = 5;
    }
    {
      name = "WEB";
      score = 3;
    }
    {
      name = "Lossless";
      score = 5;
    }
    {
      name = "Vinyl";
      score = -10;
    }
  ];
in
{
  systemd.services.lidarr-config-setup = {
    description = "Configure Lidarr naming, quality and custom formats";
    after = [
      "k3s-apps.target"
      "arr-credentials-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
    wants = [ "arr-credentials-setup.service" ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "lidarr-config-setup" ''
        ${k8s.libShSource}
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        set +e

        setup_preamble "${markerFile}" "Lidarr configuration"
        wait_for_k3s

        ${arr.helpers}

        if ! arr_usable lidarr; then
          create_marker "${markerFile}"
          exit 0
        fi

        arr_patch lidarr config/naming ${lib.escapeShellArg namingFilter} naming
        arr_patch lidarr config/mediamanagement ${lib.escapeShellArg mgmtFilter} "media management"
        arr_patch lidarr qualitydefinition ${lib.escapeShellArg qualityDefsFilter} \
          "quality definitions" qualitydefinition/update

        ${lib.concatMapStringsSep "\n        " ensureFormat customFormats}

        SCORES=${lib.escapeShellArg (builtins.toJSON formatScores)}
        ALL_CFS=$(arr_get lidarr customformat)
        PROFILES=$(arr_get lidarr qualityprofile)

        if [ -n "$PROFILES" ] && [ -n "$ALL_CFS" ]; then
          PROFILE_ID=$(echo "$PROFILES" | $JQ -r '.[0].id // empty')
          if [ -n "$PROFILE_ID" ]; then
            UPDATED_PROFILE=$(echo "$PROFILES" | $JQ \
              --argjson cfs "$ALL_CFS" --argjson scores "$SCORES" '
              .[0]
              | .upgradeAllowed = true
              | .minFormatScore = 1
              | .formatItems = [
                  $scores[] as $s
                  | ($cfs[] | select(.name == $s.name) | .id) as $id
                  | { format: $id, name: $s.name, score: $s.score }
                ]
            ')
            arr_put lidarr "qualityprofile/$PROFILE_ID" "$UPDATED_PROFILE" >/dev/null 2>&1
            echo "  Lidarr: quality profile updated (upgrades, CF scores, min score: 1)"
          fi
        fi

        echo ""
        echo "=== Lidarr configuration complete ==="

        create_marker "${markerFile}"
      '';
    };
  };
}
