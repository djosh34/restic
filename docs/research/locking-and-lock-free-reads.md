# Research: can a full backup be browsed from another machine while restic is writing?

Ticket: #3 (part of map #1). Researched 2026-10-10 against **restic 0.19.1** (released 2026-07-05, tag commit `6aa3a516`), the latest release. Source links point at the `v0.19.1` tag unless stated otherwise.

## TL;DR

- **A running `restic backup` does not stop other machines from reading.** Backup takes a *non-exclusive* lock, and non-exclusive locks coexist. Readers (`snapshots`, `ls`, `find`, `restore`, `dump`, `mount`, `diff`, `stats`, `cat`) take non-exclusive locks too. Only *exclusive* operations conflict with readers: `prune`, `forget`, `check`, `tag`, `rewrite --forget`, the `repair` commands, `key passwd`/`key remove`, `migrate` and `recover`. This has been true since at least 0.9.6, and I reproduced it on 0.19.1.
- **Every reader can skip locking entirely with `--no-lock`.** It has existed since 0.2.0 (2016). It is the only way to read with **read-only S3 credentials**, because taking a lock means writing a file to `locks/`. With `--no-lock`, a concurrent backup is harmless. A concurrent `prune` or `forget` can make the read fail. It cannot corrupt the repository. I reproduced both outcomes.
- **"Stale" does not mean "ignored".** No command except `restic unlock` checks whether a lock is stale. The design doc wrongly says otherwise. So a leftover **exclusive** lock (for example from a killed `forget`, `prune` or `check`) blocks *every* locking reader on every machine until someone runs `restic unlock`. Exit code is 11. Automatic stale-lock removal is still open upstream (#2736), and the roadmap targets it for 0.20.
- **What the user hit is most likely one of these, not backup-vs-reader locking:**
  1. A wrapper running `forget`, `prune` or `check` (all exclusive).
  2. A stale exclusive lock left by such a command.
  3. Read-only credentials without `--no-lock`.
  4. Most fundamentally: **the first backup never finished, so no snapshot existed to browse.**

  restic writes the snapshot only at the very end ([archiver.go L899-L987](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/archiver.go#L899-L987)). An "interrupted snapshot" feature is still an open request ([#2960](https://github.com/restic/restic/issues/2960)). So "browse the full backup while restic writes it" is impossible for an initial backup, whatever the locking.
- **Sleep/wake no longer kills a backup by itself (since 0.16.0).** The backup aborts only if another client deleted its lock while the Mac slept. That happens if someone ran `unlock` after the lock had gone 30 minutes without a refresh. I verified this on 0.19.1 with a SIGSTOP simulation (section 5).
- **Lock-free designs:** rustic never uses locks and has a two-phase prune with delayed deletion. That makes *rustic* prune safe next to readers and backups, but only if every backup finishes within `--keep-delete` (default 23 h). A 4-week first backup would need a delay of more than 4 weeks. **A pure-Go reader cannot import restic's code**: everything lives under `internal/`, and the request to expose a library is still open ([#4406](https://github.com/restic/restic/issues/4406)).

## 1. What restic locks, and how

### The lock model (0.19.1)

- A lock is an encrypted JSON file in `locks/` holding time, exclusive flag, hostname, username, PID, UID and GID ([design.rst L596-L641](https://github.com/restic/restic/blob/v0.19.1/doc/design.rst#L596-L641); [`Lock` struct, lock.go L23-L43](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L23-L43)). There are two kinds. Any number of non-exclusive locks can coexist. An exclusive lock needs *no* other lock to be present.
- How a lock is acquired ([`NewLock`, L101-L141](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L101-L141)):
  1. List and load every lock.
  2. Write its own lock.
  3. Sleep 200 ms.
  4. List again to catch a race.

  Conflict rule: an exclusive request fails on any other lock, and a non-exclusive request fails only on an exclusive lock ([`checkForOtherLocks`, L154-L216](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L154-L216)).
- A lock file that **cannot be loaded or decrypted** is not skipped. It makes acquisition fail ([L180-L186](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L180-L186)), with a hint to run `unlock --remove-all` ([repository/lock.go L85-L87](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L85-L87)). This strictness arrived in 0.15.0 ([#2715 entry](https://github.com/restic/restic/blob/v0.19.1/changelog/0.15.0_2023-01-12/issue-2715)). Only *empty* lock files are ignored ([L448-L452](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L448-L452); 0.15.1, [PR #4152](https://github.com/restic/restic/pull/4152)).
- The CLI has three helpers ([cmd/restic/lock.go L11-L52](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/lock.go#L11-L52)):
  - `openWithReadLock`: non-exclusive, skipped when `--no-lock` is set.
  - `openWithAppendLock`: non-exclusive, skipped only in dry-run.
  - `openWithExclusiveLock`.

  The source itself admits that read-only behaviour isn't enforced yet: "TODO enforce read-only operations…" ([L39-L41](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/lock.go#L39-L41)).
- On a conflict, restic exits with **code 11** (since 0.17.0, [#956 / PR #4884](https://github.com/restic/restic/blob/v0.19.1/changelog/0.17.0_2024-07-26/pull-4884)).

### Which commands take which lock (0.19.1, from `grep openWith*Lock cmd/restic`)

| Lock | Commands | `--no-lock` honoured? |
|---|---|---|
| read (non-exclusive) | `snapshots` [L85](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_snapshots.go#L85), `ls` [L368](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_ls.go#L368), `find` [L637](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_find.go#L637), `restore` [L149](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_restore.go#L149), `dump` [L154](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_dump.go#L154), `mount` [L144](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_mount.go#L144), `diff`, `stats`, `cat`, `list`, `key list`, `copy` (source side) | **yes** |
| append (non-exclusive) | `backup` [L534](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L534), `copy` (destination), `key add`, `rewrite` (without `--forget`) | no (only `--dry-run` skips it) |
| exclusive | `prune` [L174-L179](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_prune.go#L174-L179), `forget` [L188-L193](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_forget.go#L188-L193), `check` [L242-L245](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_check.go#L242-L245), `tag` [L132-L133](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_tag.go#L132-L133), `rewrite --forget`, `repair index/packs/snapshots`, `key passwd/remove`, `migrate`, `recover` | `check`: yes. `prune`/`forget`: only together with `--dry-run`. Others: no |
| none | `list locks` (always lock-free), `unlock` | n/a |

History behind the table:
- `ls` did **not** lock at all before 0.17.0. It does by default since then ([PR #4709](https://github.com/restic/restic/blob/v0.19.1/changelog/0.17.0_2024-07-26/pull-4709)).
- `tag` stopped honouring `--no-lock` in that same change.
- `mount --no-lock` works since 0.10.0 ([PR #2821](https://github.com/restic/restic/pull/2821)). `copy --no-lock` for the source works since 0.13.0 ([#3518](https://github.com/restic/restic/issues/3518)). `key list --no-lock` works since 0.16.1 ([#4513](https://github.com/restic/restic/issues/4513)).

### Why restic locks at all

The repository format is built for concurrent appends: pack files are written first, then the index, then the snapshot ([design.rst "Read and Write Ordering", L643-L692](https://github.com/restic/restic/blob/v0.19.1/doc/design.rst#L643-L692)). Locks exist only to keep **deletion** (`prune`, `forget`, repair) away from everyone else: "A client removing data *must* acquire an exclusive lock first" ([L687](https://github.com/restic/restic/blob/v0.19.1/doc/design.rst#L687)). Reader locks exist solely so that `prune` waits for readers. MichaelEischer, 0.16.1: "Running `restic diff --no-lock` concurrently to `prune` can result in errors due to removed files and is therefore not the default" ([#4546](https://github.com/restic/restic/issues/4546#issuecomment-1786001190)).

## 2. Stale locks: what "stale" means, and what it does not

- A lock is *stale* if its timestamp is more than 30 minutes old, or if it was created on this host and the PID no longer answers SIGHUP ([`Stale`, L252-L288](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L252-L288); [`processExists`, lock_unix.go](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock_unix.go)).
- **Only `restic unlock` ever calls `Stale()`** ([`RemoveStaleLocks`, repository/lock.go L273-L294](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L273-L294); the only caller is [cmd_unlock.go L56-L58](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_unlock.go#L56-L58)). Acquisition never ignores a stale lock: `checkForOtherLocks` has no staleness check, and had none in 0.9.6 or 0.12.1 either. Maintainer statement: "All commands except `unlock` never check whether a lock is stale. They just check whether any lock exists." ([MichaelEischer, #3732, 2022-05-14](https://github.com/restic/restic/issues/3732#issuecomment-1126723009)).
- **Doc bug:** [design.rst L627-L633](https://github.com/restic/restic/blob/v0.19.1/doc/design.rst#L627-L633) says acquisition tests whether locks are stale. That is not what the code does. Anyone building on the design doc should rely on the code.
- `unlock` removes only stale locks. `unlock --remove-all` removes everything, including live locks ([L296-L307](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L296-L307)).
- Consequence: a stale **non-exclusive** lock (from a killed backup) blocks only exclusive commands. A stale **exclusive** lock blocks everything that locks, including readers on other machines, until someone runs `unlock`.
- Auto-removal of stale locks is requested in [#2736](https://github.com/restic/restic/issues/2736) (open; a 24 h threshold was discussed in [this comment](https://github.com/restic/restic/issues/2736#issuecomment-1296349012)). It is on the [roadmap](https://forum.restic.net/t/roadmap-for-restic-0-17-to-0-19/7197/1) under "Restic 0.20" (post last edited 2025-03-31), and is not in 0.19.1.

## 3. Refresh, sleep/wake, and when a running command aborts

- Locks are refreshed every **5 min**. Each refresh writes a new lock file and deletes the old one ([`Refresh`, L307-L330](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L307-L330); [interval, repository/lock.go L29](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L29)).
- If no refresh succeeds for **22.5 min** (30 min − 1.5 × 5 min, which allows for clock skew; [L31-L38](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L31-L38)), the monitor tries to recover. It deliberately polls wall-clock time every second, because Go timers pause during standby ([L183-L243](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L183-L243); [golang/go#35012](https://github.com/golang/go/issues/35012)).
- Recovery ([`tryRefreshStaleLock`, L245-L262](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L245-L262); [`RefreshStaleLock`, lock.go L332-L380](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L332-L380)):
  1. Freeze all non-lock backend operations.
  2. Check that the old lock file **still exists**.
  3. Write a new lock and check again.
  4. If the old lock is gone, cancel the command with `Fatal: failed to refresh lock in time`.
- History:
  - 0.10.0: refresh updates the timestamp ([#2390](https://github.com/restic/restic/issues/2390)).
  - 0.15.0: commands are cancelled when the refresh deadline passes ([#2715](https://github.com/restic/restic/issues/2715), [PR #3569](https://github.com/restic/restic/pull/3569)). This is what made 0.15.x backups die on every laptop suspend ([#4274](https://github.com/restic/restic/issues/4274), 0.15.1).
  - 0.16.0: the safe "continue if my lock still exists" recovery above ([PR #4374](https://github.com/restic/restic/pull/4374)), plus lock I/O no longer queued behind slow uploads ([#4199](https://github.com/restic/restic/issues/4199), [PR #4304](https://github.com/restic/restic/pull/4304)).
- Net effect on 0.16.0 and later: **sleep alone does not abort a backup.** It aborts only if another client ran `unlock` (or `unlock --remove-all`) while the Mac slept. The abort is intentional. Otherwise a resumed backup could publish a snapshot pointing at packs that a concurrent `prune` had deleted ([#2715](https://github.com/restic/restic/issues/2715); the race is explained on the [forum](https://forum.restic.net/t/backup-clients-and-sleep-interruptions/1904/3)).

## 4. `--no-lock` and `--retry-lock`

- `--no-lock`, a global flag ([global.go L100](https://github.com/restic/restic/blob/v0.19.1/internal/global/global.go#L100)), was added for read-only media in [PR #350](https://github.com/restic/restic/pull/350) and released in 0.2.0. Maintainer rule: "commands that modify the repository will ignore `--no-lock`. Most other commands should support the flag." ([#4250](https://github.com/restic/restic/issues/4250#issuecomment-1500390181)). It has **no effect on `backup`**, which always locks ([forum](https://forum.restic.net/t/any-way-to-get-restic-to-work-with-s3-object-locking-or-a-read-only-key/6858/4); [#1544](https://github.com/restic/restic/issues/1544#issuecomment-357500831)). An unlocked-backup PR was rejected ([#1917](https://github.com/restic/restic/pull/1917#issuecomment-722299864)).
- Read-only S3 works: an IAM read-only user failed on `s3:PutObject` to `locks/`. With `--no-lock` and the read-only IAM policy, it worked ([forum 2025-04](https://forum.restic.net/t/can-you-configure-read-only-access-to-an-s3-restic-backup/9644/3)). The same applies to B2 ([#4653](https://github.com/restic/restic/issues/4653#issuecomment-1937816716), 0.16.2).
- Is a lock-free read safe? It only reads. "it's totally fine to `backup` to the repository at the same time that you `restore`" ([forum, rawtaz](https://forum.restic.net/t/is-restoring-with-no-lock-safe/8383/5)). The only risk is that a concurrent `prune` deletes a pack mid-read and the read fails (reproduced in section 5).
- `--retry-lock <duration>`: added in 0.16.0 ([#719](https://github.com/restic/restic/issues/719), [PR #4107](https://github.com/restic/restic/pull/4107)). It waits 5 s, doubles up to 60 s, and makes a final attempt at the deadline ([repository/lock.go L46-L90](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L46-L90)). It **does not remove stale locks**: against a dead process's exclusive lock it simply waits out the full timeout. 0.17.1 fixed retry failures when a lock file failed to load ([#5005](https://github.com/restic/restic/blob/v0.19.1/changelog/0.17.1_2024-09-05/issue-5005)).

## 5. Experiments (restic 0.19.1 built from the tag, local backend, Linux arm64)

Lock logic does not depend on the backend: S3 talks to `locks/` through the same `SaveUnpacked`/`RemoveUnpacked`/`List` calls. I could not run S3 itself here because the MinIO container image could not be pulled. Scripts are in `/tmp/lockexp/` on the research machine. A rate-limited backup (`--limit-upload 2048`) of 400 MiB:

| Scenario | Result |
|---|---|
| `restic snapshots` while backup runs | exit 0. A second, non-exclusive lock coexists. **Output is empty: no snapshot exists until the backup finishes.** |
| `forget --keep-last 1` or `check` while backup runs | exit 11, `repository is already locked by PID … on <host>` |
| `check --no-lock` while backup runs | exit 0, "no errors were found" |
| `kill -9` backup, then `snapshots` | exit 0. The stale non-exclusive lock does not block readers. `forget` still fails with exit 11 until `unlock` ("successfully removed 1 locks") |
| `kill -9` an exclusive `check`, then `snapshots` | exit 11, "repository is already locked exclusively by PID …", **even though that PID is dead on the same host** |
| …same, `snapshots --retry-lock 20s` | waits the full 20 s, then fails. A stale lock is never treated as absent |
| …same, `snapshots --no-lock` / `ls latest --no-lock` | works |
| Repository made read-only (`chmod -R a-w`), `snapshots` | `unable to create lock in backend: … permission denied`. With `--no-lock`: works; `restore --no-lock`: restored 400 MiB |
| `restore --no-lock` (throttled) while another client runs `forget <that snapshot> --prune` | prune proceeds (the reader has no lock to block it) and deletes 26 packs. Restore fails: `ReadFull(<data/cfe255e1f0>): … no such file or directory`, "Restored 3 / 41 files", `Fatal: There were 252 errors`. **The repository itself is untouched; only the read failed.** |
| Backup paused with SIGSTOP for 24 min (past the 22.5 min deadline, under the 30 min stale limit), then SIGCONT | **Backup continued and finished**: exit 0, `snapshot c7bc3f05 saved`, with 33:59 of wall time including the pause. The stale-lock recovery found its old lock still present and carried on |
| Backup paused for 31 min, another client runs `restic unlock` meanwhile, then SIGCONT | `unlock` printed "successfully removed 1 locks". On wake the backup logged `failed to refresh stale lock: lock file was removed in the meantime`, then `Fatal: unable to save snapshot: context canceled`. **Exit code 130** (the same code as Ctrl-C), and no snapshot was saved |

SIGSTOP is only an approximation of macOS sleep: during real sleep the network also drops. The code path is the same, because the monitor uses wall-clock time ([L184-L195](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L184-L195)).

## 6. How safe are lock-free reads against a concurrent writer?

- **Concurrent `backup`: safe by design.** Writers add packs, then index, then snapshot. Readers must list snapshots *before* loading the index ([design.rst L676-L684](https://github.com/restic/restic/blob/v0.19.1/doc/design.rst#L676-L684)). A reader that follows this order never sees a snapshot whose data it can't find. During a backup, index files are flushed every 10 min or 50,000 blobs ([index.go L96-L119](https://github.com/restic/restic/blob/v0.19.1/internal/repository/index/index.go#L96-L119)), but no tree root becomes visible until the snapshot file is written at the end ([archiver.go L983](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/archiver.go#L983)).
- **Concurrent `forget`:** snapshot files can vanish, so the read returns an error. MichaelEischer: no-lock snapshot listing "can at worst error if a snapshot disappears" ([#3652](https://github.com/restic/restic/issues/3652#issuecomment-1045306137)).
- **Concurrent `prune`:** packs and index files vanish, and reads fail midway (section 5). MichaelEischer called the failures for a `mount --no-lock` during prune "strange/random" ([forum](https://forum.restic.net/t/samba-shared-restic-mount/3835/2)).
- **Long-lived readers:** `restic mount` reloads the snapshot list at most every 60 s, and reloads the index only when the set of snapshot IDs changes ([snapshots_dirstruct.go L290-L341](https://github.com/restic/restic/blob/v0.19.1/internal/fuse/snapshots_dirstruct.go#L290-L341)). This is the right model for a browsing client.
- **The trade-off of a locking reader:** a reader that does take a lock pushes the risk onto the writer side. A mount held open for a long time blocks nightly `forget`/`check`/`prune` ([forum, Samba mount](https://forum.restic.net/t/samba-shared-restic-mount/3835)). Exclusive maintenance in turn blocks readers and backups ([Backrest #244](https://github.com/garethgeorge/backrest/issues/244), fixed by the user with `--retry-lock 5m`).

## 7. Other tools that read restic repositories

- **rustic** (latest v0.11.4, 2026-08-18, actively maintained) never creates or honours lock files. Its prune is two-phase:
  1. Obsolete packs move into a `packs_to_delete` index section with a timestamp.
  2. A later prune deletes them once they are older than `--keep-delete` (default 23 h), or recovers them if they are referenced again.

  `--instant-delete` turns this off ([FAQ](https://rustic.cli.rs/docs/FAQ.html#how-does-the-lock-free-prune-work); [indexfile.rs](https://github.com/rustic-rs/rustic_core/blob/647d00f6adde3c77836dccd9bbac61a7817e0591/crates/core/src/repofile/indexfile.rs#L19-L76); [prune.rs L72-L145](https://github.com/rustic-rs/rustic_core/blob/647d00f6adde3c77836dccd9bbac61a7817e0591/crates/core/src/commands/prune.rs#L72-L145)).

  The stated condition is that every concurrent backup must finish within `--keep-delete` ([FAQ](https://github.com/rustic-rs/docs/blob/716e29d450d59318b6dd7bbe322f747c09fc8ca4/src/FAQ.md#L87-L132)).

  Compatibility with restic:
  - It reads restic repository format v1 and v2.
  - restic ignores the extra index fields (plain `json.Unmarshal`, [index.go](https://github.com/restic/restic/blob/5127c4abf921857fde4ae51f566c86028c8c2911/internal/repository/index/index.go#L526-L556)).
  - `rustic prune` next to `restic backup` is supported.
  - `restic prune` next to rustic is **not** safe ([FAQ compatibility](https://github.com/rustic-rs/docs/blob/716e29d450d59318b6dd7bbe322f747c09fc8ca4/src/FAQ.md#L22-L46)).

  A long-lived rustic reader can still lose packs once the grace period passes.
- **restic-browser** shells out to restic and always adds `--no-lock` ([command.rs L192-L203](https://github.com/emuell/restic-browser/blob/0b7c8dd195025031f39a2c6e6eec4c211d0bbf5c/src-tauri/src/restic/command.rs#L192-L203)). A read-only S3 key had failed before that ([#144](https://github.com/emuell/restic-browser/issues/144)).
- **Backrest** shells out to restic. It passes `--no-lock` only for directory listing; snapshots, restore and dump take read locks ([restic.go L332-L343](https://github.com/garethgeorge/backrest/blob/148ba12c12a7a4fef6d3c6c8e675ca2c5e7d3635/pkg/restic/restic.go#L332-L343)). It runs an exclusive `forget` after backups by default, which blocks other hosts ([#244](https://github.com/garethgeorge/backrest/issues/244)). A lock-free snapshot indexing request is still open ([#664](https://github.com/garethgeorge/backrest/issues/664)).
- **resticprofile**: its own `--no-lock` controls *its* profile lock, not restic's ([docs](https://github.com/creativeprojects/resticprofile/blob/65f413515e297b8df19404e8cf1d8223a90bea6e/docs/content/usage/_index.md#L78-L97)).
- **Native Go:** restic's packages are `internal/`, so they cannot be imported from another module ([Go 1.4 internal packages](https://go.dev/doc/go1.4#internalpackages); [#4406](https://github.com/restic/restic/issues/4406), open). `rubiojr/rapi` is a public-path copy of restic's code that reads without locking. It supports only repository format v1, and its last commit was 2023-02-27 ([README](https://github.com/rubiojr/rapi/blob/53483ec82e1758db47676d5ef7546935f50e645c/README.md#L42-L50)). Note also that restic master is moving the lock code from `internal/restic` into `internal/repository` (commits `b892b1a15`…`0f4236cb3` after v0.19.1). Copied code would drift.

## 8. Upstream status of "lock-free" restic

- [#1141 "replace lock files with two-phase compaction"](https://github.com/restic/restic/issues/1141) has been **open since 2017**. Proposals include mappu's, gebi's three-phase variant, cdhowie's upgradeable lock and [fd0's design gist](https://gist.github.com/fd0/d24abf8301724988919c80e65aba9b6d) (written for 0.9.2). fd0 (2017): "I have a hard time understanding how to apply this to restic without changing the repository format completely".
- The [roadmap](https://forum.restic.net/t/roadmap-for-restic-0-17-to-0-19/7197/1) lists "Start concurrent prune discussion #1141" for 0.19, and for 0.20: "Non-blocking prune #1141" and "automatic removal of stale locks #2736". **Neither shipped in 0.19.x.** The 0.17–0.19.1 changelog has no lock-protocol change beyond these fixes:
  - `prune --dry-run --no-lock` (0.17.3)
  - lock retry (0.17.1)
  - `chmod` and SFTP lock-deletion bugs (0.19.0, [#5595](https://github.com/restic/restic/blob/v0.19.1/changelog/0.19.0_2026-06-09/issue-5595); 0.19.1, [#21895](https://github.com/restic/restic/blob/v0.19.1/changelog/0.19.1_2026-07-05/issue-21895))
- Automatic read-only backend detection ([#351](https://github.com/restic/restic/issues/351)) was never implemented.
- On master after 0.19.1 there is only refactoring of the lock code. No `changelog/unreleased` entry concerns locks. There is one RAM-relevant entry: the in-memory index is about 12 % smaller ([PR #21937](https://github.com/restic/restic/pull/21937)).

## 9. What users report

The pattern across about 25 threads: the lock pain is **maintenance contention, abandoned locks and refresh failures**. Ordinary backup-vs-reader blocking does not appear.
- A user first blamed backup, then found that a *`forget`* from another host was what failed ([forum 4836](https://forum.restic.net/t/locks-being-created-and-not-cleared/4836/7)).
- A sleeping OS X laptop left stale locks that blocked automated `check` but not backups ([forum 584](https://forum.restic.net/t/safely-removing-locks-from-anacron-processes/584)).
- "Scheduled backup failures after sleep on OS X" (2024, no diagnosis; [forum 7421](https://forum.restic.net/t/scheduled-backup-failures-after-sleep-on-os-x/7421)).
- Large initial backups dying on suspend on 0.15.1 ([#4274](https://github.com/restic/restic/issues/4274)).
- About 50 machines restoring from one S3 repository saw roughly 100 s waits on lock listing. The advice was `--no-lock` ([#3652](https://github.com/restic/restic/issues/3652), 0.12.1).
- A user running a GUI with cancel left a lock behind ([Backrest #526](https://github.com/garethgeorge/backrest/issues/526), restic 0.17.1 on macOS).
- Positive reports: a `mount --no-lock` web-exposed browse service ([forum 5042](https://forum.restic.net/t/read-only-mount-for-latest-snapshot-with-systemd/5042)), and adding snapshots while mounted ([forum 4057](https://forum.restic.net/t/thank-you-for-restic/4057/17)).
- No report found shows a `--no-lock` read damaging a repository.

## 10. Verdict on the user's experience

| Complaint | Verdict (restic 0.19.1) |
|---|---|
| "Could not view the backup from another machine because of locking" | **Partly wrong use, partly still open.** A running backup never blocked readers, and `--no-lock` has existed since 0.2.0 (needed anyway with read-only keys). What is **still open**: (a) a stale exclusive lock blocks every locking reader until a manual `unlock`, with no auto-expiry (#2736, planned for 0.20); (b) wrappers run exclusive `forget`/`check` after each backup; (c) a corrupt lock file blocks everything (since 0.15.0). Separately, **there was nothing to browse**: an unfinished first backup has no snapshot, and no partial-snapshot feature exists (#2960, open). |
| "Kept failing across sleep/wake" (lock part) | **Fixed in 0.16.0** for the lock part. On 0.15.x every suspend over about 22 min killed the backup. Since 0.16.0 the backup survives unless another client removed its lock meanwhile (section 5). Network and backend errors after wake are a separate topic. |

## Implications for the map

**Read-only client**
- It can be lock-free and needs no fork. Give it a **read-only IAM key** (`s3:ListBucket` plus `s3:GetObject` on the repository prefix, no `PutObject`/`DeleteObject`). It then physically cannot leave locks or damage the repository, and every read must use `--no-lock` (or a native reader that never writes `locks/`).
- Read order: list snapshots, then load the index, then read trees and packs. Treat "pack/index/snapshot not found" as "repository changed underneath me": reload snapshots and index, then retry. Never treat it as corruption.
- For a long-lived browse session, copy `restic mount`'s approach: reload snapshots at most every 60 s, and the index only when the set of snapshots changes.
- The client's RAM cost is the full in-memory index, the same as restic's. That ticket should consider the about 12 % reduction coming after 0.19.1.
- **Decision needed: shell out vs native reader.**
  - **Shell-out** (`restic --no-lock --json snapshots/ls/find/dump/restore`, as restic-browser does) needs zero fork and tracks upstream automatically.
  - **Native pure-Go** means copying restic's read path (BSD-2-Clause) into a public package or re-implementing the documented format. That is a read-only fork in practice: `internal/` cannot be imported (#4406), and rapi shows the code rots (v1 only, stale since 2023).
  - Recommendation: start with shell-out for the CLI. Revisit native only if a web UI needs random access or latency that the CLI can't give.

**Supervisor daemon**
- Require **restic ≥ 0.16.0**, preferably 0.19.1. Below that, sleep kills backups and lock I/O can starve behind slow uploads.
- Always pass `--retry-lock` (for example 1h) and treat exit code 11 as "retry later".
- Treat lock loss as a normal restartable interruption, not a failure. It can show up as `Fatal: failed to refresh lock in time`, **or as exit 130 with `failed to refresh stale lock: lock file was removed in the meantime`**. Exit 130 is the same code as a user Ctrl-C, so the supervisor must parse stderr or JSON output to tell the two apart (section 5). Data already uploaded and indexed is reused through deduplication.
- Before each run, `restic unlock` (stale-only) is safe **only because the Mac is the sole writer.** Never run `--remove-all` automatically.
- Never run `unlock` from *another* host on a timer. That is exactly what aborts a sleeping Mac's backup (section 5, scenario B).
- **Own all exclusive operations** (`forget`, `prune`, `check`, `tag`) in the supervisor, schedule them between backups, and **don't run them during the first backup at all.** Every exclusive run blocks the backup, and it blocks locking readers if it dies. The client must never run them.
- **Browsing during the first backup needs the supervisor to make snapshots along the way.** restic has no partial or interrupted snapshots (#2960). Hand to the resumability ticket: back up the tree in slices (for example, a growing set of top-level directories, each run producing a tagged snapshot) so the client sees progress within weeks rather than at the end.

**Low disk / low RAM**
- Locking itself costs almost nothing: lock files are about 200 B, written every 5 min.
- The reader with `--no-lock` still writes the local cache unless given `--no-cache`. That is cheap for a remote viewer but matters on the full Mac (cache ticket).
- `check` creates a temporary cache of its own, seen in section 5 (`using temporary cache in /tmp/restic-check-cache-…`). The supervisor should watch that cache on a nearly full disk.

**New questions and decisions for the map**
1. Shell-out vs native reader for the read-only client (recommendation above).
2. Is a lock-free *prune* ever needed? If the supervisor prunes only between backups, restic's exclusive prune is fine. rustic prune next to a restic writer would need `--keep-delete` longer than the longest backup, which is more than 4 weeks for the first one. Proposal: no rustic, no prune during the first backup.
3. IAM layout: one key for the Mac (read/write; must be able to delete in `locks/`) and one read-only key for viewers. Should the Mac's key be denied deletes outside `locks/` (append-only style, [forum 6858](https://forum.restic.net/t/any-way-to-get-restic-to-work-with-s3-object-locking-or-a-read-only-key/6858/10)), with prune run elsewhere? That is a security/ops decision outside this ticket.
4. Slicing the first backup into snapshots: who owns this, the supervisor or the resumability ticket? It is the real blocker for "browse while writing".
