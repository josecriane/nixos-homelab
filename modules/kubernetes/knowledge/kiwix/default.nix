# Kiwix - Offline Wikipedia + iFixit
# Declared via bjw-s/app-template Helm library chart. The kiwix-update systemd
# service runs on the host and rollout-restarts the Helm-managed Deployment
# whenever fresh ZIM files land on /mnt/nas2/kiwix.
{
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "kiwix";
  aria2c = "${pkgs.aria2}/bin/aria2c";

  cloudNas = lib.findFirst (cfg: (cfg.enabled or false) && (cfg.cloudPaths or { }) ? "kiwix") null (
    lib.attrValues (serverConfig.nas or { })
  );
  cloudHostPath =
    if cloudNas != null then "/mnt/${cloudNas.hostname}/${cloudNas.cloudPaths.kiwix}" else null;

  release = k8s.createHelmRelease {
    name = "kiwix-serve";
    namespace = ns;
    tier = "extras";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = ./values.yaml;
    waitFor = "kiwix-serve";
    ingress = {
      host = "wiki";
      service = "kiwix-serve";
      port = 8080;
    };
  };
in
lib.recursiveUpdate release {
  systemd.services.kiwix-serve-setup = {
    after = (release.systemd.services.kiwix-serve-setup.after or [ ]) ++ [
      "nfs-storage-cloud-setup.service"
    ];
    wants = [ "nfs-storage-cloud-setup.service" ];
  };

  # kiwix-update: downloads ZIM files from download.kiwix.org on a timer.
  # Runs on the host (not in a pod), calls kubectl to rollout-restart the
  # kiwix-serve Deployment when new content lands.
  systemd.services.kiwix-update = {
    description = "Update Kiwix ZIM files";
    after = [
      "kiwix-serve-setup.service"
      "nfs-storage-cloud-setup.service"
    ];
    wants = [
      "kiwix-serve-setup.service"
      "nfs-storage-cloud-setup.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "24h";
      ExecStart = pkgs.writeShellScript "kiwix-update" ''
        ${k8s.libShSource}
        set -e

        ${
          if cloudHostPath == null then
            ''
              echo "ERROR: No cloudPaths.kiwix configured in NAS config"
              exit 1
            ''
          else
            ''
              ZIM_DIR="${cloudHostPath}"
            ''
        }

        if [ ! -d "$ZIM_DIR" ]; then
          echo "ERROR: ZIM directory $ZIM_DIR does not exist"
          exit 1
        fi

        DOWNLOADED=false

        download_latest_zim() {
          local category="$1"
          local pattern="$2"

          echo "Checking $category/$pattern..."

          local listing
          listing=$($CURL -s "https://download.kiwix.org/zim/$category/")
          if [ -z "$listing" ]; then
            echo "  ERROR: Could not fetch listing for $category"
            return 1
          fi

          local latest
          latest=$(echo "$listing" | grep -oP "''${pattern}_[0-9-]+\.zim(?=\")" | sort -V | tail -1)
          if [ -z "$latest" ]; then
            echo "  ERROR: No ZIM found matching $pattern"
            return 1
          fi

          echo "  Latest: $latest"

          if [ -f "$ZIM_DIR/$latest" ]; then
            echo "  Already up to date, skipping"
            return 0
          fi

          echo "  Downloading $latest..."
          ${aria2c} -x 8 -c -d "$ZIM_DIR" \
            "https://download.kiwix.org/zim/$category/$latest"

          if [ $? -eq 0 ] && [ -f "$ZIM_DIR/$latest" ]; then
            echo "  Download complete"
            DOWNLOADED=true

            for old_file in "$ZIM_DIR"/''${pattern}_*.zim; do
              if [ -f "$old_file" ] && [ "$(basename "$old_file")" != "$latest" ]; then
                echo "  Removing old version: $(basename "$old_file")"
                rm -f "$old_file"
              fi
            done
          else
            echo "  ERROR: Download failed for $latest"
            return 1
          fi
        }

        # === Wikipedia & iFixit ===
        download_latest_zim "wikipedia" "wikipedia_en_all_maxi"
        download_latest_zim "wikipedia" "wikipedia_es_all_maxi"
        download_latest_zim "ifixit" "ifixit_en_all"
        download_latest_zim "ifixit" "ifixit_es_all"

        # === Medicine ===
        download_latest_zim "other" "zimgit-medicine_en"
        download_latest_zim "zimit" "nhs.uk_en_medicines"
        download_latest_zim "zimit" "fas-military-medicine_en"
        download_latest_zim "zimit" "wwwnc.cdc.gov_en_all"
        download_latest_zim "zimit" "medlineplus.gov_en_all"
        download_latest_zim "wikipedia" "wikipedia_en_medicine_maxi"
        download_latest_zim "libretexts" "libretexts.org_en_med"
        download_latest_zim "other" "librepathology_en_all_maxi"

        # === Survival & Preparedness ===
        download_latest_zim "videos" "canadian_prepper_winterprepping_en"
        download_latest_zim "videos" "canadian_prepper_bugoutroll_en"
        download_latest_zim "videos" "canadian_prepper_bugoutconcepts_en"
        download_latest_zim "videos" "urban-prepper_en_all"
        download_latest_zim "videos" "canadian_prepper_preppingfood_en"
        download_latest_zim "gutenberg" "gutenberg_en_lcc-u"

        # === Education (Essential only) ===
        download_latest_zim "wikibooks" "wikibooks_en_all_nopic"

        # === DIY & Repair ===
        download_latest_zim "stack_exchange" "woodworking.stackexchange.com_en_all"
        download_latest_zim "stack_exchange" "mechanics.stackexchange.com_en_all"
        download_latest_zim "stack_exchange" "diy.stackexchange.com_en_all"

        # === Agriculture & Food ===
        download_latest_zim "zimit" "foss.cooking_en_all"
        download_latest_zim "zimit" "based.cooking_en_all"
        download_latest_zim "stack_exchange" "gardening.stackexchange.com_en_all"
        download_latest_zim "stack_exchange" "cooking.stackexchange.com_en_all"
        download_latest_zim "other" "zimgit-food-preparation_en"
        download_latest_zim "videos" "lrnselfreliance_en_all"
        download_latest_zim "gutenberg" "gutenberg_en_lcc-s"

        # === Computing & Technology ===
        download_latest_zim "freecodecamp" "freecodecamp_en_all"
        download_latest_zim "devdocs" "devdocs_en_python"
        download_latest_zim "devdocs" "devdocs_en_javascript"
        download_latest_zim "devdocs" "devdocs_en_html"
        download_latest_zim "devdocs" "devdocs_en_css"
        download_latest_zim "stack_exchange" "arduino.stackexchange.com_en_all"
        download_latest_zim "stack_exchange" "raspberrypi.stackexchange.com_en_all"
        download_latest_zim "devdocs" "devdocs_en_node"
        download_latest_zim "devdocs" "devdocs_en_react"
        download_latest_zim "devdocs" "devdocs_en_git"
        download_latest_zim "stack_exchange" "electronics.stackexchange.com_en_all"
        download_latest_zim "stack_exchange" "robotics.stackexchange.com_en_all"
        download_latest_zim "devdocs" "devdocs_en_docker"
        download_latest_zim "devdocs" "devdocs_en_bash"

        if [ "$DOWNLOADED" = "true" ]; then
          echo "New ZIM files downloaded, restarting kiwix-serve..."
          $KUBECTL rollout restart deployment/kiwix-serve -n ${ns}
          $KUBECTL rollout status deployment/kiwix-serve -n ${ns} --timeout=120s || true
          echo "kiwix-serve restarted"
        else
          echo "No new ZIM files, no restart needed"
        fi

        echo "Kiwix update complete"
      '';
    };
  };

  systemd.timers.kiwix-update = {
    description = "Weekly Kiwix ZIM update";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon *-*-* 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
