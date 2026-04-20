# OpenStreetMap - offline world maps.
# Serves PMTiles via nginx + MapLibre GL JS frontend. Map data is stored on
# the NAS via cloudPaths.openstreetmap and exposed as a ReadOnly mount.
# Base assets (fonts, sprites, JS libs) are seeded once on first boot and
# refreshed by a monthly timer that pulls the latest Protomaps world build.
{
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "openstreetmap";

  cloudNas = lib.findFirst (
    cfg: (cfg.enabled or false) && (cfg.cloudPaths or { }) ? "openstreetmap"
  ) null (lib.attrValues (serverConfig.nas or { }));
  cloudHostPath =
    if cloudNas != null then "/mnt/${cloudNas.hostname}/${cloudNas.cloudPaths.openstreetmap}" else null;

  pvManifest = pkgs.writeText "openstreetmap-pv.yaml" ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: openstreetmap-data-pv
    spec:
      capacity: { storage: 1Ti }
      accessModes: [ReadWriteOnce]
      persistentVolumeReclaimPolicy: Retain
      storageClassName: nas-storage
      hostPath:
        path: ${if cloudHostPath != null then cloudHostPath else "/var/lib/openstreetmap"}
        type: DirectoryOrCreate
  '';

  pvcManifest = pkgs.writeText "openstreetmap-pvc.yaml" ''
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: openstreetmap-data
      namespace: ${ns}
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: nas-storage
      resources:
        requests: { storage: 1Ti }
      volumeName: openstreetmap-data-pv
  '';

  viewerHtml = builtins.readFile ./index.html;
  nginxConf = builtins.readFile ./nginx.conf;

  viewerConfigMap = pkgs.writeText "openstreetmap-configmap.yaml" ''
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: maplibre-viewer
      namespace: ${ns}
    data:
      index.html: |
    ${lib.concatMapStringsSep "\n" (l: "    " + l) (lib.splitString "\n" viewerHtml)}
      nginx.conf: |
    ${lib.concatMapStringsSep "\n" (l: "    " + l) (lib.splitString "\n" nginxConf)}
  '';

  assetsDir = if cloudHostPath != null then cloudHostPath else "/var/lib/openstreetmap";

  preHelm = pkgs.writeShellScript "openstreetmap-pre-helm" ''
    ${k8s.libShSource}
    wait_for_k3s
    setup_namespace "${ns}"

    if ! $KUBECTL get pv openstreetmap-data-pv >/dev/null 2>&1; then
      ${
        if cloudHostPath != null then
          ''
            mkdir -p "${cloudHostPath}" 2>/dev/null || true
            chmod 777 "${cloudHostPath}" 2>/dev/null || true
            $KUBECTL apply -f ${pvManifest}
          ''
        else
          ''echo "WARNING: no cloudPaths.openstreetmap configured"''
      }
    fi

    if ! $KUBECTL -n ${ns} get pvc openstreetmap-data >/dev/null 2>&1; then
      $KUBECTL apply -f ${pvcManifest}
      for i in $(seq 1 30); do
        STATUS=$($KUBECTL -n ${ns} get pvc openstreetmap-data -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
        [ "$STATUS" = "Bound" ] && break
        sleep 5
      done
    fi

    ASSETS_DIR="${assetsDir}"
    if [ ! -f "$ASSETS_DIR/nomad-base-styles.json" ]; then
      echo "Downloading base map assets..."
      ${pkgs.aria2}/bin/aria2c -x 4 -d "$ASSETS_DIR" -o "base-assets.tar.gz" \
        "https://github.com/Crosstalk-Solutions/project-nomad-maps/raw/refs/heads/master/base-assets.tar.gz"
      PATH="${pkgs.gzip}/bin:$PATH" ${pkgs.gnutar}/bin/tar xzf "$ASSETS_DIR/base-assets.tar.gz" \
        -C "$ASSETS_DIR" --strip-components=1 --no-same-owner
      rm -f "$ASSETS_DIR/base-assets.tar.gz"
    fi

    JS_DIR="$ASSETS_DIR/js"
    mkdir -p "$JS_DIR"
    if [ ! -f "$JS_DIR/maplibre-gl.js" ]; then
      $CURL -sL "https://unpkg.com/maplibre-gl@5.21.0/dist/maplibre-gl.js" -o "$JS_DIR/maplibre-gl.js"
      $CURL -sL "https://unpkg.com/maplibre-gl@5.21.0/dist/maplibre-gl.css" -o "$JS_DIR/maplibre-gl.css"
      $CURL -sL "https://unpkg.com/pmtiles@4.4.0/dist/pmtiles.js" -o "$JS_DIR/pmtiles.js"
    fi

    HOST="$(hostname maps)"
    cat "$ASSETS_DIR/nomad-base-styles.json" | \
      $JQ --arg host "https://$HOST" \
        '.sources.protomaps.url = "pmtiles://" + $host + "/data/world.pmtiles" |
         .sprite = $host + "/assets/sprites/v4/light" |
         .glyphs = $host + "/assets/fonts/{fontstack}/{range}.pbf"' \
      > "$ASSETS_DIR/style.json"

    $KUBECTL apply -f ${viewerConfigMap}
  '';

  release = k8s.createHelmRelease {
    name = "openstreetmap";
    namespace = ns;
    tier = "extras";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = ./values.yaml;
    waitFor = "openstreetmap";
    ingress = {
      host = "maps";
      service = "openstreetmap";
      port = 8080;
    };
  };
in
lib.recursiveUpdate release {
  systemd.services.openstreetmap-setup = {
    after = (release.systemd.services.openstreetmap-setup.after or [ ]) ++ [
      "nfs-storage-setup.service"
    ];
    wants = [ "nfs-storage-setup.service" ];
    serviceConfig.ExecStartPre = "${preHelm}";
  };

  # Monthly world.pmtiles refresh (~120 GB from build.protomaps.com).
  systemd.services.openstreetmap-update = {
    description = "Update OpenStreetMap PMTiles data";
    after = [
      "openstreetmap-setup.service"
      "nfs-storage-setup.service"
    ];
    wants = [
      "openstreetmap-setup.service"
      "nfs-storage-setup.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "48h";
      ExecStart = pkgs.writeShellScript "openstreetmap-update" ''
        ${k8s.libShSource}
        set -e
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

        ${
          if cloudHostPath == null then
            ''
              echo "ERROR: No cloudPaths.openstreetmap configured"
              exit 1
            ''
          else
            ''DATA_DIR="${cloudHostPath}"''
        }

        if [ ! -d "$DATA_DIR" ]; then
          echo "ERROR: Data directory $DATA_DIR does not exist"
          exit 1
        fi

        BUILDS_URL="https://build.protomaps.com"
        LATEST=$($CURL -sL "$BUILDS_URL/" | grep -oP '[0-9]{8}\.pmtiles' | sort -V | tail -1)
        if [ -z "$LATEST" ]; then
          LATEST="$(date +%Y%m%d).pmtiles"
        fi
        echo "Latest build: $LATEST"

        if [ -f "$DATA_DIR/world.pmtiles" ]; then
          CURRENT_SIZE=$(stat -c%s "$DATA_DIR/world.pmtiles" 2>/dev/null || echo "0")
          REMOTE_SIZE=$($CURL -sI "$BUILDS_URL/$LATEST" | grep -i content-length | awk '{print $2}' | tr -d '\r')
          if [ -n "$REMOTE_SIZE" ] && [ "$CURRENT_SIZE" = "$REMOTE_SIZE" ]; then
            echo "Already up to date"
            exit 0
          fi
        fi

        echo "Downloading world PMTiles (~120 GB)..."
        ${pkgs.aria2}/bin/aria2c \
          -x 8 -s 8 -k 50M --continue=true \
          -d "$DATA_DIR" -o "world.pmtiles.tmp" \
          "$BUILDS_URL/$LATEST"

        if [ $? -eq 0 ] && [ -f "$DATA_DIR/world.pmtiles.tmp" ]; then
          mv "$DATA_DIR/world.pmtiles.tmp" "$DATA_DIR/world.pmtiles"
          $KUBECTL rollout restart deployment/openstreetmap -n ${ns}
          $KUBECTL rollout status deployment/openstreetmap -n ${ns} --timeout=120s || true
        else
          rm -f "$DATA_DIR/world.pmtiles.tmp"
          exit 1
        fi
      '';
    };
  };

  systemd.timers.openstreetmap-update = {
    description = "Monthly OpenStreetMap PMTiles update";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-01 03:00:00";
      Persistent = true;
      RandomizedDelaySec = "2h";
    };
  };
}
