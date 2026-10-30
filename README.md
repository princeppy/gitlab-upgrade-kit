# gitlab-upgrade-kit

A single Bash script plus a written SOP for upgrading a **self-managed GitLab (CE or EE)
Linux package / Omnibus install** on Debian or Ubuntu, safely and repeatably.

The script does everything a machine can check — preflight, disk cleanup, backup with
checksum, the required-stop upgrade path, pinned installs, migration gates, health checks,
runner matching, package holds — and **stops at the steps only a human can do**: taking a
snapshot in your cloud console, copying the backup off the server, and clicking through the UI.

Built from real upgrades of a small production instance (4 vCPU ARM64, 8 GB RAM):
18.4 → 18.11 (three hops), 18.11 → 19.4, and 19.4 → 19.5.

## Quick start

On the GitLab server, inside `tmux`:

```bash
tmux new -s gitlab
curl -fsSLO https://raw.githubusercontent.com/princeppy/gitlab-upgrade-kit/v1.0.0/gitlab-upgrade.sh
less gitlab-upgrade.sh                     # read it — it runs as root
sudo bash gitlab-upgrade.sh prepare        # preflight → cleanup report → backup → [copy off] → [snapshot]
# … shut down, snapshot, power on, reconnect, tmux again …
sudo bash gitlab-upgrade.sh resume         # upgrade hops → verify → runner → finish
```

Prefer download-then-run over `curl | bash`: you get to read it, and the script needs a
terminal for its confirmation prompts. (`curl … | sudo bash -s -- status` works for the
read-only commands.)

## How to use it

### Option A — let an AI agent run it (recommended)

Open Claude Code (or a similar agent with SSH access to the server) and say:

> **"Upgrade GitLab using gitlab-upgrade-kit."**

The agent copies the script to the server and runs it over SSH following [AGENT.md](AGENT.md).
You are only asked for what a machine cannot do:

| When the agent asks | You do |
|---|---|
| "Approve the path?" | Read the path and the version-notes links, say yes |
| "Copy the backup off" | Run the `scp` + checksum lines it gives you on your laptop; confirm the checksums match |
| "Take the snapshot" | Shut down the server, take the snapshot in your cloud console, power on, say it's back |
| "Check the browser" | `/help`, open a project, `/admin/background_migrations` |

Everything else — checks, cleanup, backup, upgrade hops, migration waits, health checks,
runner — is automatic.

### Option B — run it yourself

On the server (`ssh <ssh-alias>`):

```bash
tmux new -s gitlab
curl -fsSLO https://raw.githubusercontent.com/princeppy/gitlab-upgrade-kit/v1.0.0/gitlab-upgrade.sh

sudo bash gitlab-upgrade.sh status     # quick health look
sudo bash gitlab-upgrade.sh path       # which versions it will go through
sudo bash gitlab-upgrade.sh prepare    # checks → cleanup report → backup → asks you to copy it off
```

Copy the backup to your laptop with the commands it prints, then **shut down** the server
(not "Power off"), take the snapshot, power on, reconnect:

```bash
tmux new -s gitlab
sudo bash gitlab-upgrade.sh resume     # upgrade → verify → runner → finish
```

It stops and asks you to type `DONE` at each human step.

### Handy single commands

| Command | Use |
|---|---|
| `gitlab-upgrade.sh status` | Health check at any time |
| `gitlab-upgrade.sh cleanup` | See what disk can be freed (deletes nothing) |
| `gitlab-upgrade.sh cleanup --apply` | Actually free it (asks per item) |
| `gitlab-upgrade.sh path --target 19.8` | Plan an upgrade only as far as 19.8 |
| `gitlab-upgrade.sh help` | Full list |

### Good to know

- **Always inside `tmux`.** If your connection drops: `tmux attach -t gitlab`.
- Logs: `/root/gitlab-upgrade/logs/` on the server.
- **Never run `apt upgrade` on upgrade day.** OS updates go on another day.
- If anything fails, the script stops by itself and prints why (`✘ …` plus a
  `::result … status=fail` line).
- After each upgrade, record it in your own private copy of the SOP's history table.

## Commands

| Command | What it does | Changes the server? |
|---|---|---|
| `status` | Version, services, migrations, disk, holds | No |
| `path [--target V]` | Prints the upgrade path (required stops x.2 / x.5 / x.8 / x.11) | No |
| `preflight` | SOP phases D–E: services, PostgreSQL, deprecated config, migrations, swap, apt keys, path, disk | Only `apt-get update` |
| `cleanup [--apply]` | Reports reclaimable disk (Docker images, GitLab Runner cache volumes, disabled Prometheus data, journal, backups of other versions older than 7 days). `--apply` asks per item and refuses `--yes` | With `--apply` |
| `backup` | Copies `/etc/gitlab`, runs `gitlab-backup create STRATEGY=copy`, records sha256, prints the copy-off commands | Writes a backup |
| `upgrade` | Requires the **off-site** and **snapshot** confirmations, then for each stop: pinned `apt-get install`, wait for health, 0 pending schema migrations, Redis check, wait for batched background migrations | **Yes** |
| `verify` | `gitlab:check`, `git fsck` on every repo, Pages routing | No |
| `runner` | Moves `gitlab-runner` (+ helper images) to the newest release of the **server's** minor | Yes |
| `finish` | `apt-mark hold` on GitLab packages, prints the human checklist | Yes (holds) |
| `prepare` | `preflight` → `cleanup` → `backup` → off-site gate → snapshot how-to | |
| `resume` | `upgrade` → `verify` → `runner` → `finish` | |

Options: `--target latest|19.5|19.5.3`, `--apply`, `--yes`, `--no-tmux`.

## Safety model

- **Pinned installs only.** Every hop installs an exact version. `apt-mark hold` at the end
  means a casual `apt upgrade` can never skip a stop again.
- **Gates before and after every hop.** Nothing installs unless services are up, no schema
  migration is `down` and every batched background migration is finished. This is checked
  again on a re-run, so a timed-out gate can't be stepped over. Checks fail *closed*: if
  `rake` or `psql` can't answer, the gate fails.
- **A recorded, checksum-verified backup of the installed version** is required before `upgrade`.
- **apt plan check.** If apt wants to install or remove anything besides the GitLab package,
  a person must approve. `--yes` never approves risky prompts (apt plan, key replacement,
  deletions).
- **Config kept.** `--force-confold` keeps your `gitlab.rb` if dpkg asks.
- **Human gates cannot be skipped by `--yes`.** `upgrade` refuses to start until the off-server
  copy and the snapshot are confirmed — by typing `DONE`, or `GUK_CONFIRM_OFFSITE=yes` /
  `GUK_CONFIRM_SNAPSHOT=yes` set only after a person has done the step. Confirmations are
  recorded per version in `/root/gitlab-upgrade/gate-*`, so each is asked once per upgrade.
  Exit code `2` means "waiting for a human".
- **Never deleted:** repositories, database, `shared/*` (artifacts, registry, packages),
  `/etc/gitlab`, non-runner Docker volumes, the latest pre-upgrade backup.
- **Logs** for every run in `/root/gitlab-upgrade/logs/`.

## Letting an AI agent drive it

Every phase ends with a machine-readable line:

```
::result phase=preflight status=pass
::result phase=gate-snapshot status=waiting detail=set GUK_CONFIRM_SNAPSHOT=yes after doing it
```

See [AGENT.md](AGENT.md) for the loop an agent (Claude Code, CI, etc.) should follow over
SSH, and which steps it must hand back to a human.

## Not covered

Docker / Helm / source installs, Geo, multi-node and external PostgreSQL/Redis setups,
PostgreSQL major-version upgrades (`gitlab-ctl pg-upgrade`), RHEL-family distributions.

## Read before running

- [SOP.md](SOP.md) — the full procedure with the *why* behind each step and a gotchas table
- GitLab upgrade paths: <https://docs.gitlab.com/update/upgrade_paths/>
- Path calculator: <https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/>

## Tests

```bash
bash tests/test_path.sh          # upgrade-path logic, no root or GitLab needed (bash ≥ 4)
shellcheck -x gitlab-upgrade.sh
```

## License

Copyright © 2026 Prince PARK. **All rights reserved** — published for reference only;
no permission is granted to use, copy, modify or redistribute without written consent.
See [LICENSE](LICENSE). No warranty. Take a snapshot.
