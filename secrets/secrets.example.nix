let
  # ssh-keyscan <server-ip> | grep ed25519
  server = "ssh-ed25519 AAAA...your-server-host-key...";
  # Your personal SSH public key
  admin = "ssh-ed25519 AAAA...your-admin-key...";
  allKeys = [
    server
    admin
  ];
in
{
  "cloudflare-api-token.age".publicKeys = allKeys;
  "tailscale-auth-key.age".publicKeys = allKeys;
  "authentik-admin-password.age".publicKeys = allKeys;
  # Uncomment if authentik.google.enable = true in config.nix
  # "authentik-google-client-secret.age".publicKeys = allKeys;
  # Uncomment if useWifi = true in config.nix
  # "wifi-password.age".publicKeys = allKeys;
}
