# Shared helpers for scripts/ - read config.nix using the nodes schema.
# Usage: source "$(dirname "$0")/lib.sh"

# Resolve the bootstrap node name from config.nix (the node flagged bootstrap=true)
get_bootstrap_name() {
    local cfg="${1:-$CONFIG_FILE}"
    nix eval --impure --raw --expr "
        let cfg = import $cfg;
            names = builtins.attrNames cfg.nodes;
            bootstrap = builtins.filter (n: (cfg.nodes.\${n}.bootstrap or false)) names;
        in builtins.head bootstrap
    " 2>/dev/null
}

# Resolve the bootstrap node IP from config.nix
get_bootstrap_ip() {
    local cfg="${1:-$CONFIG_FILE}"
    nix eval --impure --raw --expr "
        let cfg = import $cfg;
            names = builtins.attrNames cfg.nodes;
            bootstrap = builtins.filter (n: (cfg.nodes.\${n}.bootstrap or false)) names;
            name = builtins.head bootstrap;
        in cfg.nodes.\${name}.ip
    " 2>/dev/null
}

# Read a top-level string value from config.nix by key (e.g. adminUser, domain)
get_config_string() {
    local key="$1"
    local cfg="${2:-$CONFIG_FILE}"
    nix eval --impure --raw --expr "(import $cfg).$key" 2>/dev/null
}
