# Contributing

Thanks for your interest in contributing to nixos-homelab.

## Getting Started

1. Fork the repository
2. Clone your fork
3. Copy config files:
   ```bash
   cp config.example.nix config.nix
   cp secrets/secrets.example.nix secrets/secrets.nix
   ```
4. Enter the dev shell: `nix develop`

## Development

### Code Style

- Run `nix fmt` before committing
- Keep modules self-contained (one systemd service per file where possible)
- Use `import ../lib.nix` for shared helpers
- Use marker files for idempotency

### Testing

```bash
nix flake check --no-build
shellcheck scripts/*.sh
```

### Adding a New Service

1. Create `modules/kubernetes/<category>/<service>.nix`
2. Add the import to `modules/kubernetes/default.nix` under the appropriate `lib.optionals` block
3. Add a `services.<name>` toggle to `config.example.nix` if it should be user-selectable
4. Use the `k8s.setupPreamble`, `k8s.createMarker` pattern for idempotency
5. Assign to the correct systemd tier (infrastructure, storage, core, media, extras)

### Commit Messages

Use conventional commits:
- `feat:` new service or feature
- `fix:` bug fix
- `refactor:` code restructuring
- `docs:` documentation only
- `ci:` CI/CD changes

## Pull Requests

- Keep PRs focused on a single change
- Include a description of what changed and why
- Make sure `nix flake check --no-build` passes

## Reporting Issues

Open an issue with:
- What you expected to happen
- What actually happened
- Your `config.nix` (redact personal data)
- Relevant logs (`journalctl -u <service>-setup`)
