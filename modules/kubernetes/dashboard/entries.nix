# Dashboard entries, declared by the module that owns each service.
#
# The options are always available, whether or not homer is enabled, so a
# module can register its entry without caring who renders it. homer reads
# `dashboard` and renders nothing when a group has no active items.
{ lib, ... }:

let
  inherit (lib) mkOption types;
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
              description = "Font Awesome class for the heading.";
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
                description = "Font Awesome class for the card.";
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
              tag = mkOption {
                description = "Short label shown next to the name.";
                type = types.nullOr types.str;
                default = null;
              };
              ping = mkOption {
                description = ''
                  Workload whose readiness turns into a status dot, as
                  `{ namespace, name }`. The URL of the check is built from the
                  switchboard host, so an entry does not have to know it.
                '';
                type = types.nullOr (
                  types.submodule {
                    options = {
                      namespace = mkOption { type = types.str; };
                      name = mkOption { type = types.str; };
                    };
                  }
                );
                default = null;
              };
              workload = mkOption {
                description = ''
                  Deployment or StatefulSet behind the entry, as `{ namespace, name }`.
                  The dashboard hides the entry while the workload has zero
                  replicas, and uses it for the status dot when `ping` is unset.
                '';
                type = types.nullOr (
                  types.submodule {
                    options = {
                      namespace = mkOption { type = types.str; };
                      name = mkOption { type = types.str; };
                    };
                  }
                );
                default = null;
              };
              card = mkOption {
                description = ''
                  Homer smart card fed through a GET-only proxy on the dashboard
                  host. `paths` are the API paths the card reads, `apiKey` names
                  the secret whose value Traefik injects as `header`.
                '';
                type = types.nullOr (
                  types.submodule {
                    options = {
                      type = mkOption { type = types.str; };
                      service = mkOption {
                        type = types.submodule {
                          options = {
                            namespace = mkOption { type = types.str; };
                            name = mkOption { type = types.str; };
                            port = mkOption { type = types.port; };
                          };
                        };
                      };
                      paths = mkOption { type = types.listOf types.str; };
                      apiKey = mkOption {
                        type = types.nullOr (
                          types.submodule {
                            options = {
                              secret = mkOption { type = types.str; };
                              key = mkOption { type = types.str; };
                              header = mkOption { type = types.str; };
                            };
                          }
                        );
                        default = null;
                      };
                      extra = mkOption {
                        type = types.attrsOf types.str;
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
      icon = "fas fa-cloud";
      sort = 10;
    };
    media = {
      title = "Media";
      icon = "fas fa-play-circle";
      sort = 20;
    };
    downloads = {
      title = "Downloads & Management";
      icon = "fas fa-tasks";
      sort = 30;
    };
    documents = {
      title = "Documents";
      icon = "fas fa-folder-open";
      sort = 35;
    };
    knowledge = {
      title = "Knowledge";
      icon = "fas fa-brain";
      sort = 40;
    };
    monitoring = {
      title = "Monitoring";
      icon = "fas fa-chart-line";
      sort = 50;
    };
    infrastructure = {
      title = "Infrastructure";
      icon = "fas fa-server";
      sort = 60;
    };
    storage = {
      title = "Storage";
      icon = "fas fa-hdd";
      sort = 70;
    };
  };
}
