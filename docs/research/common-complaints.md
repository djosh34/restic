# What else goes wrong for restic users, and is it fixed or user error?

Ticket: #7 (part of map #1). Baseline: **restic v0.19.1 (2026-07-05)**, the latest release, read at tag `v0.19.1`. Surveyed 2026-10-10.

## TL;DR

- **Most of the famous old complaints are fixed.** These include slow prune (rewritten in 0.12.0, resumable in 0.17.0), no compression (0.14.0), slow restores and no restore progress (0.10.0 and 0.16.0), no way to resume an interrupted restore (0.17.0), jobs failing on a busy lock (`--retry-lock`, 0.16.0), backups dying after standby (0.16.0), and scripts unable to tell errors apart (exit codes 10/11/12 in 0.17.x). Advice older than about 2023 is often stale.
- **These are still open in 0.19.1:**
  - no config file or profiles ([#16](https://github.com/restic/restic/issues/16), 109 reactions);
  - stale locks are not cleaned up automatically ([#2736](https://github.com/restic/restic/issues/2736));
  - no APFS snapshot support, so files that change during a backup are captured however they look when read ([#3714](https://github.com/restic/restic/issues/3714));
  - large macOS xattrs bloat tree metadata ([#3643](https://github.com/restic/restic/issues/3643));
  - Time Machine exclusions are ignored ([#2180](https://github.com/restic/restic/issues/2180));
  - macOS ACLs, birth dates and BSD flags are not preserved ([#1622](https://github.com/restic/restic/issues/1622));
  - no documented cost model for S3 operations ([#2239](https://github.com/restic/restic/issues/2239));
  - cold storage support is only partial ([#3202](https://github.com/restic/restic/issues/3202));
  - a full storage quota can block cleanup ([#3582](https://github.com/restic/restic/issues/3582)).
- **Usage mistakes the docs already cover, and which keep coming up:**
  - a lost password means lost data;
  - "wrong password" that is really a wrong S3 URL or prefix;
  - running `init` again on the restore machine;
  - `forget` without `prune` frees no space;
  - prune runs on the client, so it downloads and re-uploads data;
  - `check --read-data` downloads the whole repository;
  - backup collides with `prune` or `check`, which take exclusive locks;
  - scheduled jobs don't have the Full Disk Access (FDA) that Terminal has;
  - mount+rsync used for bulk restores;
  - `forget` grouping by host+paths keeps "old" snapshots.
- **On the user's own lock complaint:** in 0.19.1, read commands (`snapshots`, `ls`, `restore`, `mount`) take a *non-exclusive* lock, and that lock does **not** conflict with a running `backup` ([lock.go:155-159](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L155-L159)). Only `check`, `prune` and `forget` take exclusive locks. Reading from another machine while a backup runs is therefore blocked by maintenance, by a lock file that can't be read, or by having no write access for creating a lock (`--no-lock` covers that last case). The bigger gap is that an unfinished backup has **no snapshot to browse**; sibling #3 covers that.
- **The pattern:** the complaints that remain are about the glue around restic, not about losing data. That glue is config, scheduling and monitoring, lock hygiene, cost control and macOS integration (FDA, APFS, metadata). This is the gap the planned supervisor daemon would fill.

## Scope and method

- In scope: complaints *other than* the topics of the sibling tickets: interrupted first backups (#2), lock-free reads (#3), RAM and disk (#4), and scheduling, Keychain and tooling on macOS (#5). Where the user's own experience touches one of those topics, this note gives only a short verdict and links the sibling.
- Facts about behaviour come from the source and docs at tag [`v0.19.1`](https://github.com/restic/restic/tree/v0.19.1) and from the [CHANGELOG](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md). A "FIXED in X" verdict is based on the changelog at that tag (or, for a few small PRs, the first tag containing the merge commit), never on an issue merely being closed. Issue states and reaction/comment counts (R/C) were re-checked with `gh api` on 2026-10-10.
- Community evidence:
  - GitHub issues: about 190 distinct issues ranked by reactions and comments.
  - forum.restic.net: 55 topics read in full via the Discourse JSON.
  - Hacker News: full Algolia threads from 2019, 2021, 2022 and 2024.
  - Reddit: **direct access returned HTTP 403**, so the Reddit evidence is weaker. It comes from search-engine excerpts and is only cited where it agrees with another source.
- Four sub-agents did the reading legwork (via `paseo`). I re-checked their key claims against the source and `gh` before using them.

## 0. The user's own experience: verdicts

| What the user hit | Verdict at 0.19.1 | Evidence (details in the sibling tickets) |
|---|---|---|
| First backup never finished across sleep/wake; failed | **Partly fixed**, partly unchanged by design. Since 0.16.0 restic checks after standby whether it is safe to continue instead of failing with `failed to refresh lock in time` ([#4274](https://github.com/restic/restic/issues/4274), [PR #4374](https://github.com/restic/restic/pull/4374)). However, once a lock is >30 min old, other hosts may treat it as stale ([lock.go:252-262](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L252-L262)). Since 0.15.0 a backup whose lock refresh fails is cancelled ([CHANGELOG, Enh #2715](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md)), so that a `prune` on another host can't silently corrupt it. | Sibling #2 |
| Could not view the backup from another machine "because of locking" | **Probably not the lock you'd expect.** A `backup` holds a non-exclusive lock ([cmd_backup.go:534](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L534)), and so do `snapshots` and `restore` ([cmd_snapshots.go:85](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_snapshots.go#L85), [cmd_restore.go:149](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_restore.go#L149)). Non-exclusive locks only conflict with exclusive ones ([lock.go:155-159](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L155-L159)). Exclusive locks are taken by `check` ([cmd_check.go:245](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_check.go#L245)), `prune` ([cmd_prune.go:179](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_prune.go#L179)) and `forget` ([cmd_forget.go:193](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_forget.go#L193)). An unreadable lock file blocks every command ([CHANGELOG Enh #2715](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md)). `--no-lock` exists for read-only access ([global.go:100](https://github.com/restic/restic/blob/v0.19.1/internal/global/global.go#L100)). On the forum, "already locked" most often turned out to be an overlapping `forget --prune` ([forum 1269/26](https://forum.restic.net/t/1269/26.json), [forum 4836](https://forum.restic.net/t/4836.json)). | Sibling #3 |
| Painful setup, hand-written cron, wrappers made it worse, no Keychain | **Still open by design.** There is no config file ([#16](https://github.com/restic/restic/issues/16), open, 109R/71C) and no scheduler. The docs send users to cron/systemd/resticprofile ([040_backup.rst:760-771](https://github.com/restic/restic/blob/v0.19.1/doc/040_backup.rst#L760-L771)). Keychain is reachable today through `--password-command` / `RESTIC_PASSWORD_COMMAND` ([030_preparing_a_new_repo.rst:41-45](https://github.com/restic/restic/blob/v0.19.1/doc/030_preparing_a_new_repo.rst#L41-L45)), e.g. a command that calls `security find-generic-password -w`. | Sibling #5 |
| Huge RAM and local disk; the backup failed on a nearly full disk | Out of scope here, but one macOS-specific cause belongs to this ticket: **large xattrs** (e.g. `com.apple.data-container-personality` under `~/Library/Containers`) are stored inline in tree JSON ([node.go:106](https://github.com/restic/restic/blob/v0.19.1/internal/data/node.go#L106)). The result is hundreds of MB of tree metadata that is re-uploaded and cached ([#3643](https://github.com/restic/restic/issues/3643), open; [forum 3850](https://forum.restic.net/t/tracking-down-large-metadata-changes/3850)). A request to exclude xattrs at backup time was closed in favour of fixing the storage format ([#21775](https://github.com/restic/restic/issues/21775)). Also: by default `check` builds a **fresh temporary cache** ([cmd_check.go:40-41](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_check.go#L40-L41)), which uses disk on top of the normal cache. | Sibling #4 |
| Files changing during the backup | **Still open.** There is no APFS snapshot support; `--use-fs-snapshot` is registered only on Windows ([cmd_backup.go:150-152](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L150-L152); [#3714](https://github.com/restic/restic/issues/3714), open, 27R). The archiver only compares metadata against the *parent* snapshot ([archiver.go:634](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/archiver.go#L634)) and does not detect a file changing while it is read. The docs don't discuss this for macOS or Linux (the only snapshot docs are the VSS section, [040_backup.rst:70](https://github.com/restic/restic/blob/v0.19.1/doc/040_backup.rst#L70)). | Here and #2 |
| Liked S3, dedup, client-side encryption | These hold. The one recurring S3 surprise is **cost**: prune, `check --read-data` and `copy` download and re-upload data ([045_working_with_repos.rst:238-241, 499-501](https://github.com/restic/restic/blob/v0.19.1/doc/045_working_with_repos.rst#L499-L501)). | §8 |

## 1. Setup, configuration and scheduling friction

- **No config file or profiles.** Status: **still open**. [#16](https://github.com/restic/restic/issues/16) (open since 2014, 109R/71C) is the most-reacted *open* UX issue apart from the large architecture requests ([#299](https://github.com/restic/restic/issues/299) pull backups, 372R; [#187](https://github.com/restic/restic/issues/187) asymmetric keys, 143R). On HN, users who switched from restic to rustic name the config file as the reason ([HN 41089136](https://news.ycombinator.com/item?id=41089136)), and others complain about hand-maintained `backup.sh` scripts ([HN 41831332](https://news.ycombinator.com/item?id=41831332)).
- **No scheduler.** This is **by design and documented**: "Restic does not have a built-in way of scheduling backups, as it's a tool that runs when executed rather than a daemon" ([040_backup.rst:763-768](https://github.com/restic/restic/blob/v0.19.1/doc/040_backup.rst#L763-L768)). The same page asks users to "detect already running instances" themselves ([040_backup.rst:770-771](https://github.com/restic/restic/blob/v0.19.1/doc/040_backup.rst#L770-L771)). [#519](https://github.com/restic/restic/issues/519) (open, 41C) and [#2122](https://github.com/restic/restic/issues/2122) (shipping systemd units) are still open.
- **Too CLI-heavy for non-experts.** Several users chose Kopia for its UI ([HN 29212997](https://hn.algolia.com/api/v1/items/29212997), [HN 34154580](https://news.ycombinator.com/item?id=34154580)). One Mac user stopped using restic for two years over script upkeep and came back via Backrest ([HN 41836874](https://news.ycombinator.com/item?id=41836874)). A forum novice gave up and moved to Duplicati ([forum 5347/24](https://forum.restic.net/t/5347/24.json)). The usual fix is a wrapper (Backrest, resticprofile, autorestic), not leaving restic.
- **"Does this repo exist?" in scripts.** **Fixed in 0.17.0**: exit code 10 means the repository does not exist ([075_scripting.rst:134-168](https://github.com/restic/restic/blob/v0.19.1/doc/075_scripting.rst#L134-L168)). An idempotent `init` is still open ([#1690](https://github.com/restic/restic/issues/1690), 31R).
- **No `.gitignore` support.** **Still open** ([#1514](https://github.com/restic/restic/issues/1514), 70R). This is a concrete reason given for switching to rustic or Kopia ([HN 41830884](https://news.ycombinator.com/item?id=41830884), [HN 37532273](https://hn.algolia.com/api/v1/items/37532273)).
- **Testing exclusions before uploading.** **Fixed in 0.13.0**: `backup --dry-run -vv` ([#1542](https://github.com/restic/restic/issues/1542), [PR #3300](https://github.com/restic/restic/pull/3300)).

## 2. Passwords, repository URLs and `init` mistakes

- **Lost password means lost data.** This is **a documented property, not a bug.** The docs repeat "Losing your password means that your data is irrecoverably lost" ([030_preparing_a_new_repo.rst:80](https://github.com/restic/restic/blob/v0.19.1/doc/030_preparing_a_new_repo.rst#L80)). Forum regulars treat such data as gone ([forum 2990](https://forum.restic.net/t/2990.json)). Mitigation: add a second key with `key add` ([070_encryption.rst](https://restic.readthedocs.io/en/stable/070_encryption.html)) and store it offline.
- **"Wrong password or no key found" that is really a wrong location.** **User error.** Common causes:
  - wrong S3 addressing (virtual-host style instead of `s3:host/bucket/prefix`) or the wrong prefix ([forum 3547](https://forum.restic.net/t/3547.json), [#2971](https://github.com/restic/restic/issues/2971), [#923](https://github.com/restic/restic/issues/923));
  - shell `%`/`^` expansion that changed the password at `init` time;
  - passing the password itself to `-p`, which expects a *file path* ([forum 3125](https://forum.restic.net/t/3125.json));
  - another sync tool that deleted `keys/` ([forum 2038](https://forum.restic.net/t/2038.json)).

  Since 0.17.1 a wrong password returns exit code 12 ([075_scripting.rst:168](https://github.com/restic/restic/blob/v0.19.1/doc/075_scripting.rst#L168)). That doesn't help when the real cause is a wrong prefix.
- **Running `init` again on the restore machine.** **User error.** Re-running `init` on an existing repository is rejected ([forum 1182](https://forum.restic.net/t/restoring-on-a-new-host/1182)). A genuine race between two *simultaneous* `init` calls that leaves an orphan key is **still open** ([#5717](https://github.com/restic/restic/issues/5717); fix [PR #21944](https://github.com/restic/restic/pull/21944) unmerged).
- **Cloud credentials versus repository password.** **User error**, but **only partly fixed** on the UX side. Common cases: a manual `unlock` run without the exported S3 keys, and a systemd job with a different `HOME` that can't find AWS credentials ([forum 10732](https://forum.restic.net/t/10732.json), [forum 10715](https://forum.restic.net/t/10715.json)). Missing S3 credentials have produced a clear error since 0.17.0 ([PR #4908](https://github.com/restic/restic/pull/4908)). Invalid credentials or IAM permissions still often look like a missing repository ([#1671](https://github.com/restic/restic/issues/1671), open). One 0.19.1 user purged a healthy bucket because a signature error looked like corruption ([forum 10988](https://forum.restic.net/t/10988.json)).
- **A backup "hangs" while waiting at an invisible password prompt.** **Fixed in 0.19.0** ([#5477](https://github.com/restic/restic/issues/5477)).

## 3. `forget`, `prune` and `check` surprises

- **`forget` freed no space.** **Documented behaviour.** `forget` only removes snapshots; `prune` (or `forget --prune`) removes the data ([060_forget.rst:18-23](https://github.com/restic/restic/blob/v0.19.1/doc/060_forget.rst#L18-L23)). `forget --prune` only prunes if some snapshot was actually removed ([forum 4175](https://forum.restic.net/t/4175.json)).
- **"Old snapshots are never forgotten".** **Documented behaviour.** By default `forget` groups snapshots by host+paths ([cmd_forget.go:153](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_forget.go#L153); [060_forget.rst:226-231](https://github.com/restic/restic/blob/v0.19.1/doc/060_forget.rst#L226-L231)). Adding a backup path starts a new group, and the old group keeps its own snapshots under the retention policy. A related request, backup sets with stable names, is still open ([#4026](https://github.com/restic/restic/issues/4026), 23R/42C; [#2246](https://github.com/restic/restic/issues/2246) parent detection breaks when `--files-from` changes).
- **Prune takes days.** **Largely fixed:**
  - 0.12.0 redesigned prune and made repacking parallel ([PR #2718](https://github.com/restic/restic/pull/2718), [PR #2941](https://github.com/restic/restic/pull/2941); complaints in [#2162](https://github.com/restic/restic/issues/2162), [forum 2127](https://forum.restic.net/t/2127.json), [HN 19490845](https://news.ycombinator.com/item?id=19490845));
  - 0.17.0 made prune resumable and cut its memory use ([PR #4812](https://github.com/restic/restic/pull/4812), [PR #4354](https://github.com/restic/restic/pull/4354));
  - 0.19.0 repacks small packs more aggressively ([CHANGELOG Chg #5293](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md)).

  It is **still inherently client-side**. Prune downloads, repacks and re-uploads; one user over a 20 Mbit link needed to repack about 622 GiB ([forum 8093](https://forum.restic.net/t/8093.json)). The controls are `--max-unused` (default `5%`), `--max-repack-size` and `--repack-cacheable-only` ([cmd_prune.go:81-83](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_prune.go#L81-L83)).
- **Prune blocks backups.** **Documented**: "During a prune operation, the repository is locked and backups cannot be completed" ([060_forget.rst:25-29](https://github.com/restic/restic/blob/v0.19.1/doc/060_forget.rst#L25-L29)). The long-standing proposal to remove that limitation, lock-free two-phase compaction ([#1141](https://github.com/restic/restic/issues/1141), 16R/26C), is **still open**.
- **Repository full, so prune can't run.** **Partly fixed in 0.14.0**: `prune --max-repack-size 0` and `--unsafe-recover-no-free-space` ([PR #3481](https://github.com/restic/restic/pull/3481); [060_forget.rst:511-534](https://github.com/restic/restic/blob/v0.19.1/doc/060_forget.rst#L511-L534)). Still open: a provider *quota* that blocks even creating the lock file ([#3582](https://github.com/restic/restic/issues/3582); [#21904](https://github.com/restic/restic/issues/21904) for S3 quota retries).
- **`--max-unused` ignored when there are many duplicate blobs.** **Fixed in 0.18.0** ([PR #5212](https://github.com/restic/restic/pull/5212), [forum 8879](https://forum.restic.net/t/8879.json)).
- **`check` says "repository contains errors" after a normal prune.** **Fixed in 0.14.0**: `--check-unused` was deprecated ([#3295](https://github.com/restic/restic/issues/3295)).
- **`check` reports corruption that a retry had already fixed.** **Fixed in 0.18.1** ([#5467](https://github.com/restic/restic/issues/5467), [PR #5495](https://github.com/restic/restic/pull/5495)).
- **`check --read-data` is expensive.** **Documented**: it downloads all packs ([045_working_with_repos.rst:499-501](https://github.com/restic/restic/blob/v0.19.1/doc/045_working_with_repos.rst#L499-L501)). Use `--read-data-subset=n/t` or `x%`. Since 0.19.0, `check` can also be limited to selected snapshots ([CHANGELOG Enh #3326](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md)). B2 users who ran `check` and `prune` after every backup were surprised by daily downloads of about 23 GB ([forum 4176](https://forum.restic.net/t/4176.json)).

## 4. Locks

- **Stale locks block unattended jobs until someone runs `unlock`.** **Still open** ([#2736](https://github.com/restic/restic/issues/2736), open, 11R/18C). The common workaround is running `restic unlock` before each job (`ExecStartPre=restic unlock`, [HN 41963832](https://news.ycombinator.com/item?id=41963832)). Plain `unlock` only removes *stale* locks, so the workaround is safe; `unlock --remove-all` is not. The rules for a stale lock ([lock.go:252-288](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L252-L288); [design.rst](https://github.com/restic/restic/blob/v0.19.1/doc/design.rst)):
  - the lock's timestamp is more than **30 min** old; or
  - the lock was created **on this host** and its PID is gone.

  A lock from **another host** is never stale before 30 min. A live process refreshes its lock every 5 min ([repository/lock.go:29-37](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L29-L37)).
- **Jobs fail immediately on a busy repository.** **Fixed in 0.16.0** by `--retry-lock <duration>` ([#719](https://github.com/restic/restic/issues/719), [PR #4107](https://github.com/restic/restic/pull/4107)), which backs off from 5 s up to 60 s ([repository/lock.go:31-33](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L31-L33)).
- **"Failed to refresh lock in time" after slow uploads or standby.** **Fixed in 0.16.0** ([PR #4304](https://github.com/restic/restic/pull/4304), [PR #4374](https://github.com/restic/restic/pull/4374)).
- **`unlock` says "successfully removed" but the lock is still there.** **Still open** ([#3387](https://github.com/restic/restic/issues/3387)). Since 0.15.0, `unlock` only prints the message when it actually removed a lock (Chg #3929).
- **Lock removal fails on SMB/WebDAV with "chmod not supported".** **Fixed in 0.19.0** ([#5595](https://github.com/restic/restic/issues/5595), [PR #5596](https://github.com/restic/restic/pull/5596)).
- **S3 Object Lock / Wasabi compliance mode also protects restic's `locks/`, causing deadlock.** **Still open** ([#5411](https://github.com/restic/restic/issues/5411), [forum 2318](https://forum.restic.net/t/2318.json)). This matters if the map ever adopts S3 Object Lock for ransomware protection.

## 5. Restore

- **Restores much slower than backup.** **Fixed for the known bottlenecks**: 0.9.4 made restores concurrent and 0.10.0 sped up large files ([#2074](https://github.com/restic/restic/issues/2074), [PR #1719](https://github.com/restic/restic/pull/1719), [PR #2195](https://github.com/restic/restic/pull/2195); [forum 2878](https://forum.restic.net/t/2878.json), [forum 3054](https://forum.restic.net/t/3054.json)).
- **No progress output, and an interrupted restore starts over.** **Fixed**: progress in 0.16.0 ([PR #3991](https://github.com/restic/restic/pull/3991)). Since 0.17.0 a restore re-uses content already at the target and fetches only mismatching parts; `--overwrite` controls this ([#407](https://github.com/restic/restic/issues/407), [PR #4838](https://github.com/restic/restic/pull/4838), [050_restore.rst](https://restic.readthedocs.io/en/stable/050_restore.html)).
- **Bulk restore through `mount` + rsync is slow.** **User error.** FUSE reads are sequential and limited by latency, and maintainers advise against it for large restores ([forum 4042](https://forum.restic.net/t/4042.json), a 22 TB case). Users still pick it because of the "restart from scratch" problem fixed in 0.17.0 ([Reddit r/restic, via search index](https://search.brave.com/search?q=site%3Areddit.com%2Fr%2Frestic+restic+prune+locks+errors+restore&source=web)).
- **Applying metadata is serial and slow for millions of files.** **Still open** ([#3340](https://github.com/restic/restic/issues/3340); [forum 7329](https://forum.restic.net/t/7329.json), 13.5 M files on EFS).
- **Restore path confusion.** **User error.** `--path` selects *snapshots*, not files; `<snapshot>:<subdir>` changes the base path. Separately, backup and restore treat exclusions differently, which can make `--delete` remove the wrong content; that is **still open** ([#5253](https://github.com/restic/restic/issues/5253)).

## 6. Error messages and scripting

- **Exit codes.** **Fixed for the main cases.** The current codes ([075_scripting.rst:143-168](https://github.com/restic/restic/blob/v0.19.1/doc/075_scripting.rst#L143-L168)):

  | Code | Meaning |
  |---|---|
  | 0 | success |
  | 1 | failure |
  | 3 | some source files unreadable |
  | 10 | no repository |
  | 11 | lock failed |
  | 12 | wrong password |
  | 130 | cancelled |

  Finer-grained codes are **still open** ([#956](https://github.com/restic/restic/issues/956)).
- **"Unknown blob" or a stack trace on a damaged repository.** **Still open** ([#21953](https://github.com/restic/restic/issues/21953)).
- **xattr read failures now cause exit 3 (0.19.0 behaviour change).** **Still open** ([#21874](https://github.com/restic/restic/issues/21874), 10C). On macOS 26 with File Provider/Dropbox, `com.apple.security.private.scoped-bookmark-token` can't be read. 0.18 ignored this silently; since 0.19.0 the snapshot is marked incomplete. The maintainer considers the old silent behaviour a bug. 0.19.1 adds the underlying errno to the message ([PR #21896](https://github.com/restic/restic/pull/21896)). **A supervisor that treats exit 3 as failure will alarm on every run on such Macs.**
- **Logs are too terse, or list every unchanged file.** **Still open** ([#1805](https://github.com/restic/restic/issues/1805), [#1455](https://github.com/restic/restic/issues/1455)). `--json` is the stable interface; the docs promise backward-compatible fields ([075_scripting.rst:186-189](https://github.com/restic/restic/blob/v0.19.1/doc/075_scripting.rst#L186-L189)).

## 7. Upgrades and repository format v2

- **No compression.** **Fixed in 0.14.0** with repository format v2 ([#21](https://github.com/restic/restic/issues/21), [PR #3666](https://github.com/restic/restic/pull/3666)). Once a repository is v2, every client needs 0.14.0 or later ([045_working_with_repos.rst:627-637](https://github.com/restic/restic/blob/v0.19.1/doc/045_working_with_repos.rst#L627-L637)).
- **"I migrated but nothing got smaller".** **User error.** `migrate upgrade_repo_v2` only changes the format. Existing data is compressed only by `prune --repack-uncompressed`, which works in batches limited by `--max-repack-size` ([forum 5370](https://forum.restic.net/t/5370.json)).
- **Misleading migration messages.** **Fixed**: "check failed" on a repository that was already v2 (0.15.0, [PR #3913](https://github.com/restic/restic/pull/3913)) and a silent no-op on old binaries (0.17.1, [PR #4973](https://github.com/restic/restic/pull/4973)).
- **Data corruption with `--compression max`.** **Fixed**: two bugs in the zstd library, fixed in 0.16.1 and 0.16.4 ([#4523](https://github.com/restic/restic/issues/4523), [#4677](https://github.com/restic/restic/issues/4677)). The default `auto` level was not affected.
- **Legacy v1 index entries lost during prune/repair (0.17.0 to 0.18.x).** **Fixed in 0.19.0** ([#21820](https://github.com/restic/restic/issues/21820)). Only format-v1 repositories were affected.
- **0.19.0 regressions** (`snapshots --latest` grouping; SFTP deletes against Windows servers). **Fixed in 0.19.1** ([#21869](https://github.com/restic/restic/issues/21869), [#21895](https://github.com/restic/restic/issues/21895)). Lesson: pin a version and upgrade deliberately.
- **`self-update` hits GitHub rate limits.** **Fixed in 0.19.0** with an optional GitHub token ([#3738](https://github.com/restic/restic/issues/3738), [PR #5568](https://github.com/restic/restic/pull/5568)).

## 8. S3 and cloud specifics

- **Unpredictable bills.** **Still open as documentation** ([#2239](https://github.com/restic/restic/issues/2239)). The costs come from maintenance and checks rather than backups ([forum 4176](https://forum.restic.net/t/4176.json), [forum 3838](https://forum.restic.net/t/3838.json), [HN 33454505](https://news.ycombinator.com/item?id=33454505), [HN 36890228](https://news.ycombinator.com/item?id=36890228)). The docs cover the trade-off between bandwidth and wasted space ([060_forget.rst](https://restic.readthedocs.io/en/stable/060_forget.html#customizing-pruning)).
- **Glacier / Deep Archive.** **Partly supported.** 0.18.0 added experimental restore warm-up for S3 cold storage ([PR #5173](https://github.com/restic/restic/pull/5173)). It remains experimental in 0.19.1: [#3202](https://github.com/restic/restic/issues/3202) (69R) and [#5659](https://github.com/restic/restic/issues/5659) (a restore fails on `202 Accepted`) are open. Metadata (index, snapshots, trees) must stay in a hot storage tier.
- **B2 and Wasabi quirks.** Mostly user error or provider behaviour:
  - B2 "deletes" only hide object versions unless lifecycle rules are set ([forum 6462](https://forum.restic.net/t/6462.json), [forum 8962](https://forum.restic.net/t/8962.json));
  - the native B2 backend can hang, and the docs recommend using B2 through its S3 API;
  - Wasabi stopped redirecting requests sent to the wrong region ([#3909](https://github.com/restic/restic/issues/3909), open).

  None of this matters for AWS S3 proper.
- **Backend inconsistency looks like missing packs.** **Not a restic bug.** Checks recovered once the backend recovered ([forum 7498](https://forum.restic.net/t/7498.json)).

## 9. macOS-specific trouble (excluding scheduling and Keychain, covered by #5)

| Complaint | Status at 0.19.1 | Sources |
|---|---|---|
| "Operation not permitted" on Photos, Mail or `~/Library`; works in Terminal, fails under launchd | **User error / OS setup.** The process restic actually runs as (or the app that launches it) needs Full Disk Access; granting it to Terminal doesn't cover launchd. The official docs have **no** FDA recipe. Docs cover exit 3 for incomplete backups ([040_backup.rst:787-799](https://github.com/restic/restic/blob/v0.19.1/doc/040_backup.rst#L787-L799)). | [#2051](https://github.com/restic/restic/issues/2051) (70C), [forum 2848](https://forum.restic.net/t/2848.json), [forum 7150](https://forum.restic.net/t/7150.json), [HN 36479754](https://news.ycombinator.com/item?id=36479754), [#5178](https://github.com/restic/restic/issues/5178) |
| No APFS snapshot, so inconsistent live files | **Still open** | [#3714](https://github.com/restic/restic/issues/3714), [forum 4232](https://forum.restic.net/t/utilizing-macos-local-apfs-snapshots-for-restic-backups/4232) (DIY `tmutil` snapshots change the path prefix), [cmd_backup.go:150](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L150) |
| Large xattrs bloat tree metadata and cache | **Still open** | [#3643](https://github.com/restic/restic/issues/3643), [node.go:106](https://github.com/restic/restic/blob/v0.19.1/internal/data/node.go#L106) |
| Time Machine / Backup Core exclusions ignored (caches etc. are backed up) | **Still open**; [PR #21788](https://github.com/restic/restic/pull/21788) open, unmerged | [#2180](https://github.com/restic/restic/issues/2180) |
| ACLs, birth time and BSD flags (`uchg`) not restored | **Still open** (Darwin stat records only atime, mtime and ctime) | [#1622](https://github.com/restic/restic/issues/1622), [forum 10487](https://forum.restic.net/t/restore-with-macos-acls/10487), [stat_darwin.go:32-34](https://github.com/restic/restic/blob/v0.19.1/internal/fs/stat_darwin.go#L32-L34) |
| Backup downloads every iCloud "optimised storage" file and fills the disk | **Fixed in 0.19.0** with `--exclude-cloud-files`, effective from Sonoma (macOS 14) onwards; detects `SF_DATALESS` | [#5352](https://github.com/restic/restic/issues/5352), [PR #5370](https://github.com/restic/restic/pull/5370), [stat_darwin.go:44-50](https://github.com/restic/restic/blob/v0.19.1/internal/fs/stat_darwin.go#L44-L50) |
| File Provider xattr errors give exit 3 | **Still open** (see §6) | [#21874](https://github.com/restic/restic/issues/21874) |
| Photos library "re-uploaded" every run | **User error.** The progress figure counts bytes *scanned*, not uploaded; check "Added to the repository". `--ignore-ctime`/`--ignore-inode` trade correctness for speed. | [forum 2691](https://forum.restic.net/t/backing-up-macos-photos-library/2691), [cmd_backup.go:146-147](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L146-L147) |
| `mount` broken on macFUSE 4 / Apple Silicon; FUSE-T reads hang on Sonoma | **Fixed** in 0.15.0, 0.17.0 (FUSE-T support) and 0.17.3 | [#3096](https://github.com/restic/restic/issues/3096), [PR #4825](https://github.com/restic/restic/pull/4825), [#4971](https://github.com/restic/restic/issues/4971) |
| macFUSE FSKit backend (no kernel extension) can't be selected | **Still open** | [#5649](https://github.com/restic/restic/issues/5649) |
| exFAT: ENOTTY on Ventura (fixed 0.15.0); wrong file sizes on restore; UVFSService hangs or kernel panics | Mixed. Restore sizes **still open** ([#5480](https://github.com/restic/restic/issues/5480)); hangs and panics are an OS/driver problem | [#4016](https://github.com/restic/restic/issues/4016), [#4551](https://github.com/restic/restic/issues/4551), [forum 8673](https://forum.restic.net/t/mac-issues-with-exfat-external-hard-drive/8673) |
| Excel files with mtime reset not detected as changed | **Fixed in 0.9.6** (ctime is now checked) | [#2179](https://github.com/restic/restic/issues/2179), [archiver.go:634](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/archiver.go#L634) |
| Homebrew `restic/restic` tap is obsolete | **User error**: use `brew install restic` | [#2013](https://github.com/restic/restic/issues/2013), [020_installation.rst:92-99](https://github.com/restic/restic/blob/v0.19.1/doc/020_installation.rst#L92-L99) |

## 10. Corruption and trust

- Reports of "hash mismatch", "pack not found" and "ciphertext verification failed" are the scariest recurring threads ([#1999](https://github.com/restic/restic/issues/1999), 94C; [forum 8565](https://forum.restic.net/t/8565.json); [forum 7385](https://forum.restic.net/t/7385.json)). Most diagnosed cases were storage or filesystem faults (NTFS damage, truncated packs on Yandex/pCloud, StorageGRID inconsistency). The two confirmed restic bugs were the max-compression zstd bug and the v1 split-index bug, both fixed (§7). Several cases are **still unresolved** ([forum 10968](https://forum.restic.net/t/10968.json), Mega; [forum 8430](https://forum.restic.net/t/8430.json)).
- Repair tooling has matured: `repair index` and `repair snapshots` (0.16.0), `repair packs` handling truncated files (0.17.0, [PR #4644](https://github.com/restic/restic/pull/4644)), and `recover` rebuilding the index automatically (0.18.0). The [troubleshooting guide](https://github.com/restic/restic/blob/v0.19.1/doc/077_troubleshooting.rst) says to fix storage first and keep a copy of the repository before repairing. It also states that `backup` and `prune` "can be interrupted at *any* point in time without damaging the repository. You might have to run `unlock` manually though" ([077_troubleshooting.rst:19-22](https://github.com/restic/restic/blob/v0.19.1/doc/077_troubleshooting.rst#L19-L22)).
- On HN, users switched in both directions between restic and borg after corruption, without diagnosis ([HN 29210654](https://hn.algolia.com/api/v1/items/29210654) vs [HN 29209848](https://hn.algolia.com/api/v1/items/29209848)). That is anecdote, not a failure rate.

## What a well-run restic setup does differently

1. **Pins a recent release (≥0.19.1)** and reads the changelog before upgrading. Many "restic is broken" threads involve old or distro binaries ([forum 3054](https://forum.restic.net/t/3054.json): the user was still running the old binary).
2. **Two keys** (`key add`), with one recovery password stored offline. The working password comes from `--password-command` (e.g. Keychain), never `-p <string>`.
3. **Uses path-style S3 URLs and verifies them with `snapshots`** right after `init`. It treats exit codes 10, 11 and 12 differently and never deletes a bucket because of an auth error.
4. **Runs only one writer at a time and schedules maintenance on purpose.** Backups use `--retry-lock`. `forget --prune` and `check` run rarely, ideally from a host that isn't the laptop and doesn't sleep, so their exclusive lock never overlaps a backup. Plain `unlock` (never `--remove-all`) is safe before a job.
5. **Sizes maintenance to the budget.** That means `--max-unused`, `--max-repack-size` and `check --read-data-subset` rather than full reads, with egress cost in mind.
6. **Checks results, not just "snapshot saved".** It treats exit 3 as a warning (and inspects which files failed), uses `--json` for status, and has a monitor that alarms when *no* snapshot has arrived recently.
7. **On macOS:** grants FDA to the binary or app that launchd actually starts; passes `--exclude-cloud-files`; excludes `~/Library/Caches`, `/dev` and other virtual or ephemeral paths; and runs `restore --dry-run` and real test restores.

## Implications for the map

**Supervisor daemon**
- The daemon is filling a gap upstream calls deliberate: restic is "a tool that runs when executed rather than a daemon" ([040_backup.rst:763-765](https://github.com/restic/restic/blob/v0.19.1/doc/040_backup.rst#L763-L765)). [#16](https://github.com/restic/restic/issues/16) and [#519](https://github.com/restic/restic/issues/519) have been open for about 10 years. Don't expect upstream to build this; building around restic fits the "no fork" preference.
- **Exit-code policy is a design input.** Map 0/3/10/11/12/130 to distinct states. Since 0.19.0, exit 3 fires on unreadable xattrs from File Provider ([#21874](https://github.com/restic/restic/issues/21874)), so the daemon needs a per-path allow/deny list rather than "non-zero means failed".
- **Lock hygiene belongs to the daemon:** it should be the only scheduler on the Mac, use `--retry-lock`, and run plain `unlock` before starting. It should never run `prune` or `check` from the laptop during the first backup: those take exclusive locks and would block both backup and browsing.
- **FDA is the most common macOS failure that looks like user error.** The daemon must be the binary that holds FDA, or launch restic in a way that inherits it, and it must *verify* access, e.g. with a test read of a TCC-protected path. Sibling #5 should settle how.
- **Defaults the daemon should own:** `--exclude-cloud-files`, a curated macOS exclusion list (Backup Core exclusions aren't honoured, [#2180](https://github.com/restic/restic/issues/2180)), and `--password-command` reading from Keychain.
- **Files changing during the backup:** restic gives no consistency guarantee on macOS ([#3714](https://github.com/restic/restic/issues/3714)). **Decision needed:** should the daemon take and mount a local APFS snapshot (`tmutil localsnapshot` + `mount_apfs -s`) and back up from it? Doing so changes snapshot paths (see [forum 4232](https://forum.restic.net/t/4232.json)) and affects parent-snapshot detection and grouping ([#2092](https://github.com/restic/restic/issues/2092), [#2246](https://github.com/restic/restic/issues/2246)). Alternatively, accept fuzzy snapshots and rely on later runs to catch up. Over a 4-week first backup, an APFS snapshot would also pin weeks of deleted blocks on a nearly full disk, which conflicts with the low-disk goal. This should go to grilling (#6).

**Read-only client**
- With 0.19.1, read operations already coexist with `backup`. The real blockers are exclusive maintenance, unreadable or stale locks, and missing write permission. A lock-free reader (or `--no-lock`) removes the last two. A web UI for browsing is a long-standing request ([#60](https://github.com/restic/restic/issues/60), 64R), so there is user value beyond this one user.
- Show restore and metadata limits honestly: restoring metadata is serial ([#3340](https://github.com/restic/restic/issues/3340)), and macOS ACLs, flags and birth time are not stored ([#1622](https://github.com/restic/restic/issues/1622)). A client that shows "everything" may still not round-trip Mac metadata.
- Good error messages are a differentiator. Users misread auth or URL errors as corruption ([#1671](https://github.com/restic/restic/issues/1671), [forum 10988](https://forum.restic.net/t/10988.json)), and damaged-blob errors are cryptic ([#21953](https://github.com/restic/restic/issues/21953)).

**Low-disk and low-RAM goals**
- The macOS large-xattr problem ([#3643](https://github.com/restic/restic/issues/3643)) is a likely contributor to cache and RAM bloat on Macs that the generic analysis in #4 may miss. **Question for #4:** measure tree-blob size with and without `~/Library/Containers`.
- `check` builds a temporary cache by default ([cmd_check.go:40-41](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_check.go#L40-L41)). On a nearly full disk, never run `check` on the laptop, or run it with `--with-cache`.
- Without `--exclude-cloud-files`, iCloud "optimised" files are downloaded during the backup and can fill the disk on their own ([#5352](https://github.com/restic/restic/issues/5352)). This is a must-have flag.

**Cost (S3)**
- Prune and `check --read-data` cost download bandwidth ([#2239](https://github.com/restic/restic/issues/2239)). **Decision needed:** where does maintenance run (laptop, a cloud VM in the same region, or nowhere during the first backup), and on what schedule?
- If the map considers S3 Object Lock for ransomware protection, restic's lock files collide with it ([#5411](https://github.com/restic/restic/issues/5411)). Cold storage tiers are still experimental ([#3202](https://github.com/restic/restic/issues/3202), [#5659](https://github.com/restic/restic/issues/5659)), so keep the repository in S3 Standard / Standard-IA.

**New questions**
1. APFS snapshot per run: yes or no, and how to handle the path-prefix and grouping effects? (→ #6)
2. Which exit-3 causes count as acceptable, and how does the user see them? (→ #6)
3. Where and when do `forget`, `prune` and `check` run, and who owns that schedule? (→ #6; touches #3, because exclusive locks block readers)
4. Does Mac metadata fidelity (ACLs, flags, birth time) matter to the user? If yes, restic alone is not enough (#1622).
