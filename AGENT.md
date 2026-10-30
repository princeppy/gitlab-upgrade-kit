# Driving gitlab-upgrade.sh from an AI agent

This file is for an agent (Claude Code or similar) that has SSH access to the GitLab server
and a human operator available for console work. The agent does the routine work; the human
does what needs a cloud console, a browser, or judgement.

## Division of work

| Agent does | Human does |
|---|---|
| `status`, `preflight`, `cleanup` (report), `path` | Approves the target version after reading the version notes |
| `cleanup --apply` **only after the human approves the list** | Approves deletions |
| `backup` | Copies backup + `/etc/gitlab` copy off the server, verifies the checksum |
| — | Shuts the server down cleanly, takes the snapshot, powers it on |
| `resume` (inside tmux) | Watches; answers apt/config questions if any |
| `verify`, `runner`, `finish` | Browser checks (`/help`, a project, `/admin/background_migrations`), an SSH clone, tells users |

## Loop

1. Copy the script to the server and run read-only commands non-interactively:

   ```bash
   scp gitlab-upgrade.sh <host>:/root/
   ssh <host> 'bash /root/gitlab-upgrade.sh status; bash /root/gitlab-upgrade.sh preflight </dev/null'
   ```

2. Parse every `::result phase=<p> status=<pass|warn|fail|skip|waiting>` line.
   `fail` → stop and report the preceding `✘` line. `warn` → show the human, ask before continuing.

3. Show the human the path and the version-notes links printed by `preflight`. Wait for approval.

4. Long-running phases (`backup`, `upgrade`, `resume`) must run inside tmux so an SSH drop
   cannot kill them:

   ```bash
   ssh <host> 'tmux new-session -d -s gitlab "bash /root/gitlab-upgrade.sh backup --yes"'
   ssh <host> 'until ! tmux has-session -t gitlab 2>/dev/null; do sleep 15; done; tail -40 $(ls -t /root/gitlab-upgrade/logs/*backup.log | head -1)'
   ```

   `backup` ends by writing the copy-off commands to `/root/gitlab-upgrade/offsite.txt`.
   Give them to the human (replace `<ssh-alias>` with their alias). Do **not** re-run
   `backup` to "pass" a gate — that creates a second backup.

5. Human gates. With `--yes`, a gate prints instructions and exits with
   code 2 and `status=waiting`. Relay the instructions to the human, wait for them to confirm, and only
   then re-run with the matching variable:

   | Gate | Variable | Human evidence to ask for |
   |---|---|---|
   | `offsite` | `GUK_CONFIRM_OFFSITE=yes` | The laptop's `shasum -a 256` output matches the server's |
   | `snapshot` | `GUK_CONFIRM_SNAPSHOT=yes` | Snapshot name/ID shown as *Available*; server powered back on |

   **Never set a `GUK_CONFIRM_*` variable on your own judgement.** It is the human's
   statement that the work is done.

6. After the snapshot reboot: `status` first (uptime, services), then in tmux:
   `GUK_CONFIRM_OFFSITE=yes GUK_CONFIRM_SNAPSHOT=yes bash /root/gitlab-upgrade.sh resume --yes`
   (each variable only once the human has confirmed that step). `upgrade` records each
   confirmation in `/root/gitlab-upgrade/gate-<name>-<version>`. If background migrations exceed
   the timeout, ask the human before setting `GUK_FINALIZE=yes`.

7. Hand the human the checklist printed by `finish`, then update the SOP's history table.

## Rules

- Do not paste the output of `gitlab-runner list`, unfiltered `gitlab-runner verify`, or raw
  `gitlab.rb` into chats or tickets — they contain tokens and credentials. The script
  already filters its own output.
- Do not run `apt-get upgrade` in the same session. OS updates are a separate change.
- Do not delete the pre-upgrade backup or snapshot on upgrade day.
