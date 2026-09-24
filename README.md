# DEFRA multi-service analysis workspace

A workspace for **cross-service analysis** of the DEFRA Farming & Countryside
grants platform. It bundles a set of service repos as siblings, plus tooling to
clone/update them and shared Claude guidance — so anyone can reproduce the same
"work across all the repos from one folder" setup.

This repo tracks only tooling and analysis; the service repos themselves are
git-ignored and managed via `repos.txt` (see [what's tracked](#whats-tracked)).

## Quickstart

**New to this workspace** (fresh machine):

```sh
git clone <this-repo-url> DEFRA
cd DEFRA
./scripts/clone-all.sh      # clone every repo listed in repos.txt (needs GitHub SSH access)
```

**Already have this folder** (turning your existing checkout into the workspace):

```sh
cd DEFRA
git init && git add -A && git commit -m "Bootstrap analysis workspace"
```

## Everyday use

```sh
./scripts/clone-all.sh          # add any repos that are missing (safe to re-run)
./scripts/update-all.sh         # fast-forward every repo to latest main
./scripts/update-all.sh --dry-run   # preview, change nothing
```

`update-all.sh` is deliberately safe:

- Repos with **uncommitted changes** pause and ask: `[s]tash & update`, `s[k]ip`,
  or `[q]uit`. Non-interactive runs skip dirty repos automatically.
  Flags: `--stash-all`, `--skip-dirty`.
- On `main` it does `pull --ff-only`. On a feature branch it fast-forwards your
  local `main` **without** switching branches, leaving your work untouched.
- Anything stashed is reported at the end so you can `git -C <repo> stash pop`.

## Managing the repo list

`repos.txt` is the manifest. Add a bare name (uses the `# org=DEFRA` default) or a
full clone URL, then run `./scripts/clone-all.sh`. Remove a line to stop managing a
repo (its checkout stays on disk).

## What's tracked

Only `scripts/`, `skills/`, `working-area/`, `repos.txt`, `CLAUDE.md`, and
`README.md`. The `.gitignore` ignores `/*` and re-includes just those, so every
service repo — current or future — is ignored without any extra maintenance.

- `working-area/` — analysis output (notes, proposals, findings).
- `skills/` — workspace-level analysis skills (see `skills/README.md`).
- `CLAUDE.md` — guidance + a map of the platform for Claude.
