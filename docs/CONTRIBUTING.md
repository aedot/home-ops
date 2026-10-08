# Contributing

Setup:

```bash
mise install
```

`mise install` also installs the git hooks (lefthook): staged `*.sops.yaml` files must be encrypted, workflow changes run `zizmor`, and `pre-push` runs `scripts/validate-manifests.sh`.

## Workflow

1. Branch from `main` (`feat/...`, `fix/...`, `chore/...`, `docs/...`).
2. Make the change and run `scripts/validate-manifests.sh`.
3. Open a PR. `validate` and `flate` must pass; `flate` comments the rendered diff.
4. Merge. Flux applies `main`.

Commits use Conventional Commits (`type(scope): summary`) and are signed off (`git commit -s`).

## Adding an app

See "Adding a New Application" in [AGENTS.md](../AGENTS.md).

## Secrets

- Edit encrypted files with `sops <file>`. Never commit decrypted copies.
- Prefer an `ExternalSecret` (Bitwarden) over a new `*.sops.yaml`.
