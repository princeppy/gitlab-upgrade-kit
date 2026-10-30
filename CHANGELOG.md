# Changelog

## 1.0.0 — 2026-10-30

First public release, distilled from three production upgrades (18.4 → 18.11, 18.11 → 19.4,
19.4 → 19.5).

- `gitlab-upgrade.sh` with `status`, `path`, `preflight`, `cleanup`, `backup`, `upgrade`,
  `verify`, `runner`, `finish`, `prepare` and `resume`
- Required-stop path calculation (x.2/x.5/x.8/x.11, patch-first, `GUK_EXTRA_STOPS`)
- Human gates for the off-server copy and the snapshot, recorded per version; exit code 2 while waiting
- `::result` lines for AI agents and CI wrappers ([AGENT.md](AGENT.md))
- Generic SOP with gotchas ([SOP.md](SOP.md))
- Hardened after an independent review: pre-hop migration gate (also on re-runs), checks fail closed,
  backup checksum required before upgrading, gates reset by each new backup, strict apt plan,
  `--yes` never approves risky prompts, runner-only volume cleanup, keep backups younger than 7 days,
  EE version handling, atomic keyring refresh, `::result` on unexpected exits
