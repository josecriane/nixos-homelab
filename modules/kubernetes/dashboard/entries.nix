# Dashboard entries, declared by the module that owns each service.
#
# The options are always available, whether or not the dashboard is enabled,
# so a module can register its entry without caring who renders it. Homepage
# reads `dashboard` and renders nothing when a group has no active items.
{ lib, ... }:

let
  inherit (lib) mkOption types;

  iconDescription = ''
    Homepage icon: `sh-<name>` from selfh.st, `mdi-<name>` from Material
    Design Icons, `si-<name>` from Simple Icons, or a URL.
  '';
in
{
  options.dashboard = {
    groups = mkOption {
      description = "Groups of the dashboard, rendered in `sort` order.";
      default = { };
      type = types.attrsOf (
        types.submodule {
          options = {
            title = mkOption {
              description = "Heading shown on the dashboard.";
              type = types.str;
            };
            icon = mkOption {
              description = iconDescription;
              type = types.str;
            };
            sort = mkOption {
              description = "Order among the groups, lowest first.";
              type = types.int;
              default = 100;
            };
          };
        }
      );
    };

    items = mkOption {
      description = ''
        Entries of the dashboard, keyed by an identifier that only has to be
        unique. Each service registers its own from the module that installs
        it, so a service that is not installed cannot leave an entry behind.
      '';
      default = { };
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              enable = mkOption {
                description = "Whether the entry is shown.";
                type = types.bool;
                default = true;
              };
              group = mkOption {
                description = "Key of the group this entry belongs to.";
                type = types.str;
              };
              title = mkOption {
                description = "Name shown on the card.";
                type = types.str;
                default = name;
              };
              icon = mkOption {
                description = iconDescription;
                type = types.str;
              };
              subtitle = mkOption {
                description = "Second line of the card.";
                type = types.str;
              };
              url = mkOption {
                description = "Where the card links to.";
                type = types.str;
              };
              monitor = mkOption {
                description = ''
                  URL the dashboard probes for entries that run outside the
                  cluster. The card shows the response time, and the entry
                  moves to the collapsed group of stopped services while the
                  probe fails.
                '';
                type = types.nullOr types.str;
                default = null;
              };
              workload = mkOption {
                description = ''
                  Deployment or StatefulSet behind the entry. The dashboard
                  moves the entry to the collapsed group of stopped services
                  while the workload has zero replicas, and shows the state,
                  CPU and memory of its pods. Pods are matched by the label
                  `app.kubernetes.io/name=<name>` unless `selector` says
                  otherwise.
                '';
                type = types.nullOr (
                  types.submodule {
                    options = {
                      namespace = mkOption { type = types.str; };
                      name = mkOption { type = types.str; };
                      selector = mkOption {
                        description = "Label selector of the pods, when the default does not match.";
                        type = types.nullOr types.str;
                        default = null;
                      };
                    };
                  }
                );
                default = null;
              };
              widget = mkOption {
                description = ''
                  Homepage service widget. `secrets` maps a widget field such
                  as `key`, `username` or `password` to the Kubernetes secret
                  that holds its value; the dashboard copies the value into its
                  own namespace and the widget reads it through an environment
                  variable. `options` holds the remaining fields of the widget.
                '';
                type = types.nullOr (
                  types.submodule {
                    options = {
                      type = mkOption { type = types.str; };
                      url = mkOption {
                        description = "URL the dashboard uses to reach the service, usually the cluster-internal one.";
                        type = types.str;
                      };
                      secrets = mkOption {
                        type = types.attrsOf (
                          types.submodule {
                            options = {
                              namespace = mkOption { type = types.str; };
                              secret = mkOption { type = types.str; };
                              key = mkOption { type = types.str; };
                            };
                          }
                        );
                        default = { };
                      };
                      options = mkOption {
                        type = types.attrsOf (
                          types.oneOf [
                            types.str
                            types.int
                            types.bool
                          ]
                        );
                        default = { };
                      };
                    };
                  }
                );
                default = null;
              };
              sort = mkOption {
                description = "Order within the group, lowest first.";
                type = types.int;
                default = 100;
              };
            };
          }
        )
      );
    };
  };

  config.dashboard.groups = {
    cloud = {
      title = "Cloud";
      icon = "mdi-cloud";
      sort = 10;
    };
    media = {
      title = "Media";
      icon = "mdi-play-circle";
      sort = 20;
    };
    downloads = {
      title = "Downloads & Management";
      icon = "mdi-tray-arrow-down";
      sort = 30;
    };
    documents = {
      title = "Documents";
      icon = "mdi-folder-open";
      sort = 25;
    };
    requests = {
      title = "Media Requests";
      icon = "mdi-inbox-arrow-down";
      sort = 26;
    };
    knowledge = {
      title = "Knowledge";
      icon = "mdi-brain";
      sort = 40;
    };
    monitoring = {
      title = "Monitoring";
      icon = "mdi-chart-line";
      sort = 50;
    };
    infrastructure = {
      title = "Infrastructure";
      icon = "mdi-server";
      sort = 60;
    };
    storage = {
      title = "Storage";
      icon = "mdi-harddisk";
      sort = 70;
    };
  };
}
