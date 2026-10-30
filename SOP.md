# SOP — Upgrading a GitLab Linux package (Omnibus) install

For a single-node, self-managed GitLab CE/EE installed with `apt` on Debian/Ubuntu.
Each phase names the `gitlab-upgrade.sh` command that automates it. The manual commands
are listed too, so you can follow along, run it by hand, or debug the script.

**Time budget:** 15–30 minutes of hands-on work for a one-hop upgrade, plus however long
it takes to copy the backup off the server. A three-hop upgrade takes 2–4 hours, most of it
waiting on background migrations.

## Golden rules

| Rule | Why |
|---|---|
| Never skip a required upgrade stop | Each stop runs migrations the next version assumes are done |
| Always pin the exact version | An unpinned install takes the newest release and skips every stop |
| Wait for background migrations between hops | The most common cause of broken multi-hop upgrades |
| Run inside `tmux` | A dropped SSH session mid-install leaves a half-configured package |
| Back up `/etc/gitlab` yourself | `gitlab-secrets.json` is *not* in `gitlab-backup`; without it the backup cannot decrypt CI variables, 2FA or tokens |
| Snapshot with the server cleanly shut down | A running snapshot is only crash-consistent |
| One change at a time | No OS updates, config changes or reboots mixed into the upgrade |
| Hold the packages afterwards | `apt-mark hold` stops a casual `apt upgrade` from skipping stops next time |

---

## 1. Understand the path

Since GitLab 17.5, the required stops are **x.2, x.5, x.8 and x.11** of every major version.
For each stop, use the **latest patch** of that minor version.

- Crossing a major does **not** add a stop at x.0 (18.11 → 19.2 was a valid single hop).
  Always cross-check with the [official path tool](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/).
  If it lists an extra stop, pass it with `GUK_EXTRA_STOPS="18.0"`.
- If you are on a stop but not its latest patch, take the patch first (18.11.11 → 18.11.12).
- Read the version notes for every major you touch:
  `https://docs.gitlab.com/update/versions/gitlab_<major>_changes/`.
- GitLab backports security fixes only to the **three most recent minors**. Staying close to
  current keeps an emergency patch to a single command.

```bash
sudo bash gitlab-upgrade.sh path                 # → e.g. 18.5.7 18.8.11 18.11.12
sudo bash gitlab-upgrade.sh path --target 19.5   # stop at a specific minor
```

Worked examples:

| From | To | Path |
|---|---|---|
| 18.4.1 | 18.11 | 18.5.7 → 18.8.11 → 18.11.x |
| 18.11.11 | 19.4 | 18.11.12 → 19.2.x → 19.4.x |
| 19.4.1 | 19.5 | 19.5.3 |

## 2. Plan

1. Decide the target. For a security advisory, use the fixed versions listed in GitLab's own
   release post, not a third-party summary.
2. Tell your users there will be a maintenance window.
3. Check your public IP is allowed by any firewall in front of the server
   (`curl -4 https://ifconfig.me`).
4. If the instance is **publicly reachable and you are patching an actively exploited CVE**,
   restrict ports 22/80/443 to your own range at the cloud firewall *before* you start. Use
   a /24 rather than a /32, so an ISP address change doesn't lock you out. If you get locked
   out anyway, the cloud console still works.

## 3. Preflight — `gitlab-upgrade.sh preflight` (read-only)

| Check | Manual command | Pass when |
|---|---|---|
| Install type | `which gitlab-ctl`, `docker ps -a` | Package install, not a container |
| Version | `cat /opt/gitlab/embedded/service/gitlab-rails/VERSION` | Known |
| Services | `gitlab-ctl status \| grep -v '^run:'` | Prints nothing |
| PostgreSQL | `gitlab-psql -c 'SHOW server_version;'` | Meets the target major's minimum (18.x: 16, 19.x: 17) |
| Removed settings | `grep -vE '^\s*#\|^\s*$' /etc/gitlab/gitlab.rb \| grep -viE 'password\|token\|secret\|key'` | No `git_data_dirs` when crossing 18.0 |
| Schema migrations | `gitlab-rake db:migrate:status \| grep -c '^  down'` | `0` |
| Background migrations | `gitlab-psql -c "SELECT count(*) FROM batched_background_migrations WHERE status NOT IN (3,6);"` | `0` |
| Swap | `swapon --show` | Present. On 8 GB RAM, add 4 GB with swappiness 10 |
| apt keys | `apt-get update` | No `EXPKEYSIG` (see gotcha 1) |
| Target exists | `apt-cache madison gitlab-ce` | Every hop listed |
| Disk | `df -h /`, `du -sh /var/opt/gitlab` | Free ≥ size of `/var/opt/gitlab` + 8 GB |

Swap, if missing:

```bash
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
sysctl vm.swappiness=10 && echo 'vm.swappiness=10' >> /etc/sysctl.conf
```

## 4. Reclaim disk — `gitlab-upgrade.sh cleanup [--apply]`

CI-heavy servers fill up with things that are safe to delete. Report first, then remove:

| Item | Command | Safe because |
|---|---|---|
| Unused Docker images | `docker image prune -a -f` | The runner re-pulls them. Only if `docker ps` is empty |
| CI cache volumes | `docker volume ls -q --filter dangling=true \| grep '^runner-.*-cache-' \| xargs -r docker volume rm` | Caches only. Avoid `docker volume prune -a`: it also deletes *other* unused named volumes |
| Prometheus data, if monitoring is disabled | delete `/var/opt/gitlab/prometheus/data` | Only if `gitlab-ctl status prometheus` prints nothing |
| systemd journal | `journalctl --vacuum-size=500M` | Keeps the newest 500 MB |
| Backups from other GitLab versions | `rm <old>_gitlab_backup.tar` | A backup only restores into its own version |

**Never** delete repositories, the database, `shared/*` (artifacts, registry, packages) or
`/etc/gitlab`. Shrink artifacts through GitLab's expiry settings instead.

Real example: 86% → 44% used, mostly from Docker (21 GB), old Prometheus data (4.7 GB) and
the journal (3.5 GB).

## 5. Back up — `gitlab-upgrade.sh backup`

```bash
tmux new -s gitlab
mkdir -p /root/gitlab-upgrade && chmod 700 /root/gitlab-upgrade
cp -a /etc/gitlab /root/gitlab-upgrade/etc-gitlab-$(date +%Y%m%d)
gitlab-backup create STRATEGY=copy
sha256sum /var/opt/gitlab/backups/<newest>_gitlab_backup.tar
```

- `STRATEGY=copy` stages files before archiving them, which gives a more consistent tarball.
  It needs about double the space while it runs.
- The tarball includes CI artifacts, packages and registry images, so it can be far larger
  than your repositories. (Real example: 180 MB grew to 6.3 GB once CI was used heavily.)

Then **copy both off the server**, from your laptop:

```bash
D=$(date +%Y%m%d); mkdir -p ~/gitlab-backup-$D
scp <ssh-alias>:/var/opt/gitlab/backups/<file>.tar ~/gitlab-backup-$D/
scp -r <ssh-alias>:/root/gitlab-upgrade/etc-gitlab-<date> ~/gitlab-backup-$D/
shasum -a 256 ~/gitlab-backup-$D/<file>.tar        # must match the server
chmod -R go-rwx ~/gitlab-backup-$D
```

Run **both** `scp` lines. The config copy contains `gitlab-secrets.json`, plaintext
credentials and TLS private keys. Keep it out of synced folders. Allow for the transfer
time: 6 GB at 2 MB/s takes about 45 minutes.

## 6. Snapshot (human)

Order: backup → copy off → **shut down** → snapshot → power on.

1. `shutdown -h now` on the server, or **Shut down** in the console. **Not "Power off"**,
   which is a hard power cut.
2. Wait for the console to show *Off*, then take the snapshot.
3. Power on and check the reboot was clean:

```bash
uptime
gitlab-ctl status | grep -v '^run:' || echo "ALL SERVICES RUNNING"
ip -4 addr show eth0 | grep inet       # every IP your DNS points at is present
dig +short <gitlab-host> <pages-host>
```

A live snapshot is acceptable only as a *second* layer next to a verified off-server backup.
Snapshots are billed on disk blocks, so one can be larger than `df` shows.

## 7. Upgrade — `gitlab-upgrade.sh upgrade` (repeat per stop)

```bash
echo $TMUX                                    # must not be empty
apt-get update 2>&1 | grep -E "Err|EXPKEYSIG|gitlab"
apt-get install --allow-change-held-packages gitlab-ce=<version>-ce.0
```

- apt's summary must say `1 upgraded` and name only the GitLab package.
- If dpkg asks about a file in `/etc/gitlab`, **keep your version** (`N`). The script uses
  `--force-confold`.
- The install first dumps the database to `/var/opt/gitlab/backups/` (an extra rollback point),
  then unpacks, reconfigures and runs migrations. Don't interrupt it during the long quiet stretches.
- On Ubuntu, `needrestart` may restart `gitlab-runsvdir` afterwards, which restarts every
  service a second time. Wait for `/-/readiness` before you check anything.

**Gate before the next hop (all must pass):**

```bash
cat /opt/gitlab/embedded/service/gitlab-rails/VERSION
gitlab-ctl status | grep -v '^run:' || echo "ALL SERVICES RUNNING"
gitlab-rake db:migrate:status | grep "^  down" | wc -l                 # 0
gitlab-psql -c "SELECT job_class_name, table_name, status FROM batched_background_migrations WHERE status NOT IN (3,6) ORDER BY id;"   # (0 rows)
gitlab-redis-cli info server | grep redis_version; /opt/gitlab/embedded/bin/redis-server --version   # equal, else: gitlab-ctl restart redis
```

Batched migration status: 0/1 paused or pending, 2 active, 3 finished, **4 failed**,
5 finalizing, 6 finalized. If migrations are idle and nobody is using the instance, force
them with `gitlab-rake gitlab:background_migrations:finalize_all[main]`. Avoid this on large
databases with active users.

Observed migration counts: 8 (18.4→18.5), 25 (18.5→18.8), 15 (18.8→18.11), 14 (19.4→19.5).

## 8. Verify — `gitlab-upgrade.sh verify`

```bash
gitlab-rake gitlab:check SANITIZE=true 2>&1 | grep -viE "\.\.\. yes|\.\.\. ok"
gitlab-rake gitlab:git:fsck 2>&1 | grep -viE "Performed integrity check|dangling"   # only "Done"
```

`dangling` objects are harmless. `missing`, `broken link` or `error:` are real problems.

Pages: find a group that has a site, then ask nginx:

```bash
gitlab-psql -c "SELECT n.path FROM pages_deployments d JOIN projects p ON p.id=d.project_id JOIN namespaces n ON n.id=p.namespace_id WHERE d.deleted_at IS NULL LIMIT 5;"
curl -I -H "Host: <group>.<pages-domain>" http://127.0.0.1
```

`200` means public, `302` to `/auth` means access control is on, and `404` means routing works
but there's no site. A `301` to GitLab means nginx found no matching vhost. The bare Pages
domain redirecting to GitLab is normal.

**Human checks:**
- Log in, and confirm `/help` shows the new version.
- Browse a project.
- Check `/admin/background_migrations` shows 0 failed.
- `git clone` over SSH from your laptop.

## 9. Runner — `gitlab-upgrade.sh runner`

The runner is a separate package with its own versions. Match it to the **server's
minor**. A runner newer than the server can expect API features the server doesn't have.

```bash
V=$(apt-cache madison gitlab-runner | awk '{print $3}' | grep "^$(cut -d. -f1,2 /opt/gitlab/embedded/service/gitlab-rails/VERSION)\." | head -1)
apt-get install --allow-change-held-packages gitlab-runner=$V gitlab-runner-helper-images=$V
gitlab-runner verify 2>&1 | grep -E "is alive|ERROR"
```

`gitlab-runner list` and unfiltered `verify` print runner tokens, so don't paste them anywhere.
Messages like `the service is not installed` and `belongs to group docker which is insecure`
are normal during the install.

## 10. Finish — `gitlab-upgrade.sh finish`

```bash
apt-mark hold gitlab-ce gitlab-runner gitlab-runner-helper-images
```

- Reopen any temporary firewall, but keep SSH restricted.
- Tell users it's back.
- Keep the snapshot and the pre-upgrade backup for a few days, then delete them.
- Rotate anything that ended up in a chat or ticket: runner tokens, SMTP keys, PATs.
- Later, as separate changes: OS updates, `apt autoremove`, a permanent journal cap
  (`SystemMaxUse=500M`), CI artifact expiry.
- Put a monthly reminder in your calendar to check <https://about.gitlab.com/releases/>.

---

## Rollback

| Option | When | How |
|---|---|---|
| Restore the snapshot | Anything broke | Cloud console → rebuild from snapshot. Everything returns in sync; changes since are lost |
| Reinstall the old package | Only if the new version never ran migrations | `apt-get install --allow-change-held-packages gitlab-ce=<previous>` then `gitlab-ctl reconfigure` |
| Restore a backup | New server, or disk lost | Same GitLab version as the backup. Restore `gitlab-secrets.json` and `gitlab.rb` **first**, `reconfigure`, stop `puma` and `sidekiq`, `gitlab-backup restore BACKUP=<name without _gitlab_backup.tar>`, then reconfigure, restart and `gitlab:check` |
| Use the database dump taken during the install | Step back one hop | Database only, named for the *outgoing* version, in `/var/opt/gitlab/backups/` |

## Gotchas

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `EXPKEYSIG` on `apt-get update`; versions missing | GitLab repo key expired; apt silently uses a stale index | Re-download each repo's `/gpgkey` and `gpg --dearmor` it over the `signed-by` keyring (the script offers this) |
| 2 | Background migrations stuck at status 1 | The scheduler is slow by design | Wait, or `finalize_all[main]` on a quiet instance |
| 3 | `column "progress" does not exist` | The schema differs between versions | Query only `job_class_name, table_name, status` |
| 4 | Redis warning after the upgrade | The old binary is still running | `gitlab-ctl restart redis` |
| 5 | `scp` asks for the root password | Run on the server instead of the laptop | Check your prompt |
| 6 | Bare Pages domain redirects to GitLab | nginx regex needs a subdomain | Test `<group>.<pages-domain>` |
| 7 | `git_data_dirs` present when crossing 18.0 | Removed in 18.0 | Move to `gitlab_rails['repositories_storages']` first |
| 8 | Pages DNS points at an IP the server no longer has | IP added with `ip addr add`, lost on reboot | Persist it in netplan; check after every reboot |
| 9 | Disk jumps by GBs after `gitlab-backup` | Tarball includes artifacts, registry and packages | Expected; run cleanup before the backup |
| 10 | `docker volume prune` frees nothing | Runner caches are named volumes; plain prune only removes anonymous ones | Remove `runner-*-cache-*` volumes by name (`prune -a` also hits other named volumes) |
| 11 | Services restart twice after the install | `needrestart` restarts `gitlab-runsvdir` | Wait for readiness |
| 12 | `install gitlab-ce=…` refuses | Package is held | `--allow-change-held-packages` |
| 13 | The SOP says one version, the server runs another | Upgrades done without documenting them | Always start from preflight; keep a history table |
| 14 | `gitlab-runner: the service is not installed` | The installer checks before creating the systemd unit | Check with `systemctl is-active gitlab-runner` |
| 15 | "Update available" badge after patching | Points at the newest release on any branch | Ignore if you chose an older supported branch |
| 16 | Cloud firewall: `End port have to be higher than the start port` | IP typed into the port-range field | Source IPs go in the leftmost box |

## Your history table (keep it in your private copy)

| Date | Path | Notes |
|---|---|---|
| | | |
