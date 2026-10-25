{
  config,
  k8s,
  lib,
  pkgs,
  ...
}:

let
  markerFile = "/var/lib/homer-proxy-setup-done";
  homeHost = k8s.hostname "home";

  cards = lib.filterAttrs (_: item: item.enable && item.card != null) config.dashboard.items;

  routeYaml = name: namespace: matches: middlewares: service: ''
    apiVersion: traefik.io/v1alpha1
    kind: IngressRoute
    metadata:
      name: homer-proxy-${name}
      namespace: ${namespace}
    spec:
      entryPoints:
        - websecure
      routes:
    ${lib.concatMapStringsSep "\n" (match: ''
        - match: ${match}
          kind: Rule
          middlewares:
      ${lib.concatMapStringsSep "\n" (mw: "      - name: ${mw}") middlewares}
          services:
            - name: ${service.name}
              port: ${toString service.port}'') matches}
      tls:
        store:
          name: default
          namespace: traefik-system
  '';

  cardScript =
    key: item:
    let
      card = item.card;
      svcNs = card.service.namespace;
      prefix = "/proxy/${key}";
      matches = map (
        path: "Host(`${homeHost}`) && Method(`GET`) && PathPrefix(`${prefix}${path}`)"
      ) card.paths;
      middlewares = [
        "homer-proxy-${key}-strip"
      ]
      ++ lib.optional (card.apiKey != null) "homer-proxy-${key}-key";
    in
    ''
      echo "Proxy for ${key} -> ${svcNs}/${card.service.name}:${toString card.service.port}"
      cat <<'MWEOF' | $KUBECTL apply -f -
      apiVersion: traefik.io/v1alpha1
      kind: Middleware
      metadata:
        name: homer-proxy-${key}-strip
        namespace: ${svcNs}
      spec:
        stripPrefix:
          prefixes:
            - ${prefix}
      MWEOF
    ''
    + lib.optionalString (card.apiKey != null) ''
      KEY=$(get_secret_value "${svcNs}" "${card.apiKey.secret}" "${card.apiKey.key}")
      if [ -z "$KEY" ]; then
        echo "WARN: ${svcNs}/${card.apiKey.secret} has no ${card.apiKey.key}, card ${key} stays without key"
      fi
      cat <<MWEOF | $KUBECTL apply -f -
      apiVersion: traefik.io/v1alpha1
      kind: Middleware
      metadata:
        name: homer-proxy-${key}-key
        namespace: ${svcNs}
      spec:
        headers:
          customRequestHeaders:
            ${card.apiKey.header}: "$KEY"
      MWEOF
    ''
    + ''
      cat <<'RTEOF' | $KUBECTL apply --server-side --force-conflicts -f -
      ${routeYaml key svcNs matches middlewares card.service}
      RTEOF
    '';

in
{
  systemd.services.homer-proxy-setup = {
    description = "Expose dashboard card APIs on the Homer host";
    after = [
      "k3s-apps.target"
      "homer-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
    wants = [ "homer-setup.service" ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "homer-proxy-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Homer proxies"
        wait_for_k3s

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList cardScript cards)}

        print_success "Homer proxies" \
          "Cards: ${lib.concatStringsSep ", " (lib.attrNames cards)}"

        create_marker "${markerFile}"
      '';
    };
  };
}
