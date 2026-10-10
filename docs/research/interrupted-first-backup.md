# Does restic survive a weeks-long, interrupted first backup?

Ticket: #2 (part of map #1). Researched 2026-10-10 against **restic v0.19.1** (latest release, tagged 2026-07-05, commit `6aa3a516`). All source links point at the `v0.19.1` tag. Claims about older versions name them.

## TL;DR

- **Uploaded data survives an interruption, but local work and recent uploads do not.** restic writes an index file roughly every 10 minutes or every 50,000 blobs. Everything indexed is deduplicated on the next run, so it is not uploaded again. Packs uploaded after the last index write become orphans and are uploaded again. This is just as true for a clean Ctrl-C / SIGTERM, which does **not** flush the index. I reproduced both cases on v0.19.1 (see [Experiments](#experiments-v0191-local-backend)).
- **Until a first snapshot exists, every retry re-reads and re-hashes every file.** No snapshot means no parent, and no parent means nothing can be skipped by metadata. On a large Mac this is the main reason a first backup "never finishes". Upstream knows: [#2280](https://github.com/restic/restic/issues/2280) (open since 2019), [#2960](https://github.com/restic/restic/issues/2960) "interrupted snapshot" (open), and resume PRs [#3229](https://github.com/restic/restic/pull/3229) / [#3230](https://github.com/restic/restic/pull/3230) closed without merging. **No checkpoint or partial snapshot exists in v0.19.1.**
- **Sleep/wake is mostly fixed since 0.16.0**, through stale-lock refresh after standby ([#4274](https://github.com/restic/restic/issues/4274) / [#4374](https://github.com/restic/restic/pull/4374)). Stuck HTTP requests have been cut off since 0.17.0. Three failure modes remain:
  1. Another client runs `unlock` while the Mac sleeps, so on wake the backup aborts.
  2. The network is down for more than about 15 minutes after wake, so retries run out and the run aborts.
  3. S3 stalls can be hidden by minio-go's internal retries ([#22034](https://github.com/restic/restic/issues/22034), open; fix [#22048](https://github.com/restic/restic/pull/22048) not merged).
- **The user's experience, judged:**
  - "Never finished": a real limitation (not misuse), made worse by older versions' sleep bugs, which are now fixed.
  - "Couldn't view the backup from elsewhere": mostly not locking. During a first backup **there is no snapshot to view**. `backup` takes only a shared lock, which never blocks `snapshots`/`ls`/`restore`/`mount`.
  - RAM and disk: real. RAM grows with the number of blobs in the in-memory index. Disk use comes from the cache (index, plus tree packs written as they are uploaded) and, on macOS, from iCloud placeholder files being downloaded (fixed by `--exclude-cloud-files` in 0.19.0).
- **The workaround works today without a fork:** grow the backup set in steps, each producing a real snapshot, and pass an explicit `--parent` (or `--group-by host`). Then each retry only re-stats files already covered instead of re-reading them. I verified this on v0.19.1.

## 1. What "resume" means in v0.19.1

### 1.1 Uploaded packs are reused only once they are indexed

- Each pack is written to the backend and then recorded in the in-memory index via `StorePack`. That call immediately calls `saveFullIndex` ([master_index.go#L148-L151](https://github.com/restic/restic/blob/v0.19.1/internal/repository/index/master_index.go#L148-L151)).
- An index counts as "full", and is written, once it is **≥ 10 minutes old or holds ≥ 50,000 blobs** (`indexMaxAge`, `indexMaxBlobs`; [index.go#L95-L123](https://github.com/restic/restic/blob/v0.19.1/internal/repository/index/index.go#L95-L123)). The check runs only when a pack is stored ([master_index.go#L194-L215](https://github.com/restic/restic/blob/v0.19.1/internal/repository/index/master_index.go#L194-L215)).
- The remaining packers and the last index are flushed only when the backup callback **finishes successfully** ([repository.go#L565-L596](https://github.com/restic/restic/blob/v0.19.1/internal/repository/repository.go#L565-L596), [repository.go#L626-L636](https://github.com/restic/restic/blob/v0.19.1/internal/repository/repository.go#L626-L636)).
- SIGINT/SIGTERM only cancel the global context ([cleanup.go#L14-L38](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cleanup.go#L14-L38)). No flush runs on that path.
- The official FAQ says the same thing: continuation is "from where it saved the last index, which should be up to a few minutes ago" ([faq.rst#L6-L30](https://github.com/restic/restic/blob/v0.19.1/doc/faq.rst#L6-L30)). The maintainer confirms that index updates "only happen periodically" ([#4779 comment](https://github.com/restic/restic/issues/4779#issuecomment-2080449504)). Asking for a flush on SIGINT ([#2367](https://github.com/restic/restic/issues/2367)) was closed without implementing it.
- So **the work lost per interruption is up to about 10 minutes of uploads (or 50k blobs), plus packs still in flight.** It is the same for a crash, `kill -9`, Ctrl-C or SIGTERM.
- The orphaned packs are harmless. `check` reports them as "additional files" and `prune` removes them ([faq.rst#L32-L58](https://github.com/restic/restic/blob/v0.19.1/doc/faq.rst#L32-L58)). `repair index` can make them reusable instead ([forum](https://forum.restic.net/t/7453/6)). Do **not** prune between retries if you want to reuse that data ([forum](https://forum.restic.net/t/1910/2)).

### 1.2 Without a parent snapshot, every file is read again

- The parent is found with `findParentSnapshot`. It filters by host and, by default, by the **exact path set** (`--group-by host,paths`) ([cmd_backup.go#L119](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L119), [cmd_backup.go#L462-L490](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L462-L490)). If none is found, restic prints `no parent snapshot found, will read all files` ([cmd_backup.go#L561](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L561)).
- A file is skipped without being opened only if it matches its node in the parent: same type, size, mtime, ctime and inode, with all blobs still in the index ([archiver.go#L524-L553](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/archiver.go#L524-L553), [archiver.go#L634-L660](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/archiver.go#L634-L660)). Without a parent, every file is opened, chunked and hashed. Only then can a blob be found in the index and its upload skipped.
- A snapshot is written only after the whole tree has been saved ([archiver.go#L882-L960](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/archiver.go#L882-L960)). Since 0.12.0 an interrupted backup "never saves a snapshot" ([CHANGELOG.md#L4851-L4859](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L4851-L4859)).
- Maintainers have said this for years: "For resuming a backup, restic currently needs to re-read all files" ([#1704](https://github.com/restic/restic/issues/1704#issuecomment-380225054)). "Reusing cached information would require some sort of temporary snapshot" ([#2280](https://github.com/restic/restic/issues/2280#issuecomment-614262237)).

### 1.3 Upstream status of checkpoint, partial and resume features

| Item | State | Note |
|---|---|---|
| [#59](https://github.com/restic/restic/issues/59) / [#310](https://github.com/restic/restic/pull/310) "resume interrupted backups" | closed / merged 2015 (0.2.0) | Periodic index writes. This is the only "resume" that has shipped. |
| [#1183](https://github.com/restic/restic/issues/1183) "Incremental" snapshots | **open** since 2017 | Asks for a restorable partial result for slow links and sleeping machines. |
| [#1964](https://github.com/restic/restic/issues/1964) periodic snapshot while running | closed 2018 | Closed in favour of `recover` ([comment](https://github.com/restic/restic/issues/1964#issuecomment-447279088)), not because checkpoints shipped. |
| [#2280](https://github.com/restic/restic/issues/2280) reuse info from a partial backup to cut I/O | **open** since 2019 | Duplicates folded into it: [#2632](https://github.com/restic/restic/issues/2632) (a 40 TB first backup). |
| [#2960](https://github.com/restic/restic/issues/2960) save an "interrupted" snapshot on SIGINT | **open** | 2025 maintainer comment: the 0.17 signal refactor makes it feasible, but "it remains a complex change" ([comment](https://github.com/restic/restic/issues/2960#issuecomment-2746398020)). |
| [#3229](https://github.com/restic/restic/pull/3229) `--resume` | closed unmerged 2021 | Scanning unreferenced trees was too slow ([comment](https://github.com/restic/restic/pull/3229#issuecomment-761217443)). |
| [#3230](https://github.com/restic/restic/pull/3230) resume file in cache dir | closed unmerged 2024 | Stored finished dirs and their tree IDs, used as extra parents. Maintainer, 2025: "the general feature is still interesting" ([comment](https://github.com/restic/restic/pull/3230#issuecomment-3263822813)). |
| `recover` ([#2056](https://github.com/restic/restic/pull/2056), 0.9.4; reindexes automatically since 0.18.0, [CHANGELOG.md#L1135](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L1135)) | shipped | Only salvages **complete** trees that were uploaded. Trees are written bottom-up, so it gives a partial view, not a usable parent. |

A search of the v0.19.1 source finds no "checkpoint" or "resume" logic in `backup`.

## 2. Sleep/wake, network loss, kills

- **Locks during standby (fixed in 0.16.0).** A backup refreshes its lock every 5 minutes. The lock goes stale after 30 minutes. restic gives up on a normal refresh after 22.5 minutes ([repository/lock.go#L29-L38](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L29-L38), [restic/lock.go#L252-L288](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L252-L288)).
  - The refresh monitor deliberately uses wall-clock time because Go timers pause during standby ([repository/lock.go#L183-L243](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L183-L243)).
  - After a long sleep, or after a SIGSTOP, it calls `RefreshStaleLock`. That continues only if **its old lock file still exists** ([restic/lock.go#L333-L380](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L333-L380)); otherwise you get `Fatal: failed to refresh lock in time`.
  - The fix shipped in 0.16.0 ([CHANGELOG.md#L2608-L2618](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L2608-L2618), [#4274](https://github.com/restic/restic/issues/4274)). Before that, any standby longer than ~22 minutes killed the run. Users with 300 GB–6 TB first backups hit this and fell back to disabling suspend ([#4274](https://github.com/restic/restic/issues/4274)). **This probably explains much of the user's sleep/wake failure if they used a version below 0.16.**
  - Remaining hazard: `restic unlock` run from another machine while the Mac sleeps removes the lock, because the lock is older than 30 minutes ([repository/lock.go#L274-L295](https://github.com/restic/restic/blob/v0.19.1/internal/repository/lock.go#L274-L295)). The backup then aborts on wake. That is by design, to protect against a concurrent `prune` ([#4274 comment](https://github.com/restic/restic/issues/4274#issuecomment-1500377641), [forum 1904](https://forum.restic.net/t/1904/3)).
  - Note: in v0.19.1 an exclusive lock (`prune`, `check`) is refused by *any* existing lock, stale or not. Only `unlock` evaluates staleness ([restic/lock.go#L160-L216](https://github.com/restic/restic/blob/v0.19.1/internal/restic/lock.go#L160-L216)). I confirmed that a backup killed with `kill -9` blocks `check` until `unlock` is run.
- **Slow uplinks starving the lock refresh (fixed in 0.16.0):** [#4199](https://github.com/restic/restic/issues/4199) / [#4304](https://github.com/restic/restic/pull/4304).
- **Network loss.** Since 0.17.0 (the `backend-error-redesign` beta flag, on by default; [registry.go#L19](https://github.com/restic/restic/blob/v0.19.1/internal/feature/registry.go#L19)):
  - Every backend request is retried with exponential backoff for **up to 15 minutes** ([global.go#L615](https://github.com/restic/restic/blob/v0.19.1/internal/global/global.go#L615), [CHANGELOG.md#L1740-L1772](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L1740-L1772)), and always at least once more, even after a long pause ([backend_retry.go#L74-L124](https://github.com/restic/restic/blob/v0.19.1/internal/backend/retry/backend_retry.go#L74-L124)).
  - HTTP transfers with no progress for 5 minutes are cancelled and retried (`--stuck-request-timeout`, [global.go#L119](https://github.com/restic/restic/blob/v0.19.1/internal/global/global.go#L119), [CHANGELOG.md#L1508](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L1508)). The 0.17.0 changelog text still says "two minutes"; the code says 5.
  - **If the network stays down longer than the retry window, the whole run fails** ([#21904 maintainer](https://github.com/restic/restic/issues/21904#issuecomment-4762767553)).
- **Silent S3 stalls (still open).** On darwin/arm64 with 0.18.1, minio-go's internal retries hide the watchdog timeout. The upload hangs for as long as the server is unreachable while the progress timer keeps ticking ([#22034](https://github.com/restic/restic/issues/22034); fix [#22048](https://github.com/restic/restic/pull/22048) not merged). A 2021 Mac report stuck at 89% for 77 hours came from the same class of problem before 0.17 ([forum 4424](https://forum.restic.net/t/4424/14)). **A ticking timer is not progress**; a supervisor has to watch bytes uploaded.
- **Clean termination.** SIGTERM shuts down cleanly and removes the lock since 0.17.0 ([CHANGELOG.md#L1646](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L1646)). SIGINT exits with code 130 since 0.19.0 ([CHANGELOG.md#L261](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L261)). Neither saves an index or a snapshot (§1.1).
- **macOS-specific reports** I found are about local USB/exFAT repositories ([#4972](https://github.com/restic/restic/issues/4972), [#5433](https://github.com/restic/restic/issues/5433)) or scheduling ([forum 7421](https://forum.restic.net/t/7421/1), [forum 104](https://forum.restic.net/t/104/3), which notes that the network is not ready right after wake). None shows a macOS-only sleep defect with S3.

## 3. Files that change during a weeks-long backup

- restic `lstat`s the file, opens it, `fstat`s it again and refuses to continue only if the **type** changed ([archiver.go#L556-L573](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/archiver.go#L556-L573)). It then chunks until EOF and records the number of bytes it actually read ([file_saver.go#L151-L190](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/file_saver.go#L151-L190)).
- **A file modified while being read is stored torn, without a warning.** The old "file has changed" warning was removed ([#1513](https://github.com/restic/restic/issues/1513#issuecomment-703310771)). The maintainer's advice is to snapshot the filesystem ([#1708](https://github.com/restic/restic/issues/1708#issuecomment-379467669)).
- Files that disappear mid-backup are skipped since 0.18.0 ([CHANGELOG.md#L842](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L842)).
- `--use-fs-snapshot` is Windows VSS only ([cmd_backup.go#L151](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L151)). APFS snapshot support is an open request ([#3714](https://github.com/restic/restic/issues/3714)). Users script `tmutil localsnapshot` plus `mount_apfs`, which needs Full Disk Access on the wrapper ([forum 4232](https://forum.restic.net/t/4232/8)).
- For a 4-week first backup, the resulting snapshot is **not a point-in-time image** whatever you do. Each step only reflects the files as they were when that step read them. The next snapshot that uses it as parent re-reads anything whose size, mtime, ctime or inode changed, so drift heals over the following runs.

## 4. Local disk and RAM during a first backup

- **Temp packs.** Each pack is built in an unlinked temp file under `$TMPDIR` ([packer_manager.go#L202-L215](https://github.com/restic/restic/blob/v0.19.1/internal/repository/packer_manager.go#L202-L215), [file_unix.go#L16-L27](https://github.com/restic/restic/blob/v0.19.1/internal/fs/file_unix.go#L16-L27)), so a crash leaves no garbage.
  - Since 0.18.0 there are 2 open packers per blob type ([packer_manager.go#L42](https://github.com/restic/restic/blob/v0.19.1/internal/repository/packer_manager.go#L42), [CHANGELOG.md#L807](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L807)), plus one pack per upload connection (S3 default is 5; [s3/config.go#L30](https://github.com/restic/restic/blob/v0.19.1/internal/backend/s3/config.go#L30), [packer_uploader.go](https://github.com/restic/restic/blob/v0.19.1/internal/repository/packer_uploader.go#L24-L47)).
  - Worst case from the code is about (4 + 5) × 16 MiB ≈ 150 MiB. The docs' "(connections + 1) × pack size" predates the 2-packer change ([047_tuning_parameters.rst#L92-L121](https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst#L92-L121)). This is small, and it can be moved with `TMPDIR`.
- **Cache.** On macOS the cache lives in `~/Library/Caches/restic` (via `os.UserCacheDir`, [dir.go#L14-L25](https://github.com/restic/restic/blob/v0.19.1/internal/backend/cache/dir.go#L14-L25)). Every index file, every snapshot, and **every tree (metadata) pack is written to it as it is uploaded** ([cache/backend.go#L50-L93](https://github.com/restic/restic/blob/v0.19.1/internal/backend/cache/backend.go#L50-L93)).
  - There is no size cap; `--no-cache` is the only control ([forum 8040](https://forum.restic.net/t/8040/10)).
  - Users report caches of 37–240 GB for 1.2–1.6 TB repos ([forum 2352](https://forum.restic.net/t/2352/8)) and nearly 600 GB for 32 TB / 65M files ([forum 1836](https://forum.restic.net/t/1836/1)).
  - macOS xattrs (folder icons, container metadata) inflate the metadata a lot ([forum 3850](https://forum.restic.net/t/3850/9), [#3643](https://github.com/restic/restic/issues/3643)).
  - Since 0.16.0, a full cache disk cancels the command instead of crawling ([CHANGELOG.md#L2834](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L2834)). **On a nearly full disk that is exactly "the backup failed".**
  - `--no-cache` ([global.go#L104](https://github.com/restic/restic/blob/v0.19.1/internal/global/global.go#L104)) costs little for a *first* backup, because there is no parent tree to read. Later runs fetch the parent's trees from S3 on demand: slower and more requests, but no local disk.
- **iCloud placeholders.** Before 0.19.0, reading "optimized storage" files forced them to download, which can fill a nearly full disk on its own. `--exclude-cloud-files` fixes this on macOS 14+ ([CHANGELOG.md#L507-L519](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L507-L519), [cmd_backup.go#L154](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L154)).
- **RAM.** The whole repository index is held in memory ([repository.go#L705](https://github.com/restic/restic/blob/v0.19.1/internal/repository/repository.go#L705)). One `indexEntry` is a 32-byte ID plus about 28 bytes ([indexmap.go#L246-L253](https://github.com/restic/restic/blob/v0.19.1/internal/repository/index/indexmap.go#L246-L253)).
  - Maintainers estimate "1GB RAM … for every 7 millions blobs" ([forum 8758](https://forum.restic.net/t/8758/2)), or about 62 bytes per entry plus overhead ([forum 10783](https://forum.restic.net/t/10783/2)). A 1.2 TB repo with ~150M blobs needed about 30 GB.
  - Earlier reductions: 0.10.0 (up to 50%, [CHANGELOG.md#L5831](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L5831)), 0.16.0 (up to 25% and `GOGC=50`, [CHANGELOG.md#L2752](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L2752), [main.go#L128-L134](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/main.go#L128-L134)).
  - *My estimate, not measured:* a Mac with ~3M files and ~1.5 TB of large files has roughly 4–5M blobs, which comes to about 0.6–1 GB of index RAM by the end of the first backup. That is acceptable, but it grows as the repo grows. Many tiny files cost more than many bytes.
- **`--read-concurrency`** (default 2, [archiver.go#L155-L160](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/archiver.go#L155-L160), [cmd_backup.go#L133](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L133)) only sets how many files are read in parallel. Raising it speeds up the re-read phase on NVMe ([tuning docs](https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst)), at the cost of more read buffers in RAM. It does not affect resume semantics.

## 5. User reports (by theme)

- **First backup stuck in a re-read loop:**
  - 1.8 TB / 5 weeks to B2: "restic will have to re-hash everything locally", which took about 4 h per 1.5 TB on HDD ([forum 2815](https://forum.restic.net/t/2815/3), [timings](https://forum.restic.net/t/2815/4)).
  - 1–8 TB with many small files on slow drives: each retry spends its whole window catching up ([forum 3470](https://forum.restic.net/t/3470/1)).
  - 55 TiB in overnight windows: weeks of runs, an empty snapshot list; it only completed after a long weekend run ([forum 8800](https://forum.restic.net/t/8800/11)).
  - HN users worked around it by excluding big directories and adding them back gradually ([HN](https://news.ycombinator.com/item?id=39125919)), the same workaround as §6.
- **Ctrl-C myths:** an early forum answer claimed SIGINT writes the index; a user test showed it does not ([forum 1910](https://forum.restic.net/t/1910/14)). A short Ctrl-C test "re-uploads", which is the 10-minute window at work ([forum 7453](https://forum.restic.net/t/7453/6)).
- **Misleading progress after restart:** the ETA was badly wrong (improved in 0.16.0); "processed" bytes are not uploaded bytes ([forum 3396](https://forum.restic.net/t/3396/6), [forum 3843](https://forum.restic.net/t/3843/3)).
- **Locks and browsing:** `backup`, `snapshots`, `ls`, `restore` and `mount` take shared locks and coexist; `prune`, `forget` and `check` are exclusive ([forum 2048](https://forum.restic.net/t/2048/2); v0.19.1 code: `openWithReadLock` / `openWithAppendLock`, [cmd/restic/lock.go#L38-L55](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/lock.go#L38-L55)). Read commands also accept `--no-lock`.
- **Reddit** was not reachable (HTTP 403 / login wall), so no Reddit claims are included.

## 6. Judging the user's experience

| Complaint | Verdict (v0.19.1) |
|---|---|
| First backup never finished across sleep/wake | **Partly fixed.** The standby lock abort is fixed since 0.16.0, and stuck requests are cut off since 0.17.0. **Still open:** every retry re-reads everything until the first snapshot exists; up to 10 minutes of uploads are lost per interruption; a run aborts after about 15 minutes without network; S3 stalls can be silent (#22034). |
| Progress stalled | Some of it is the re-read phase, which looks like a stall. Some is the real pre-0.17 backend hang, now mostly fixed. Silent S3 stalls are still open. |
| Could not view the full backup elsewhere because of locks | **Mostly a misdiagnosis.** No snapshot exists until the first backup completes, so there is nothing to browse. Shared locks don't block readers. Stale locks only block *exclusive* commands. |
| Cron setup and no Keychain | Out of scope for restic. The FAQ now documents `RESTIC_PASSWORD_COMMAND` with `security find-generic-password` ([forum 9637](https://forum.restic.net/t/9637/8)). Covered by other tickets. |
| Enormous RAM | **Real, by design.** The index lives in memory and grows with blob count. It has been reduced several times but is not bounded. |
| Local disk filled and the backup failed | **Real.** Uncapped metadata cache (`--no-cache` avoids it), iCloud downloads (fixed in 0.19.0 with a flag), and temp packs (small). Using restic's defaults on a nearly full disk counts as "used it wrong" only in the sense that `--no-cache` / `--exclude-cloud-files` were needed. |

## Experiments (v0.19.1, local backend)

The binary was built from tag v0.19.1 on linux/arm64. The data set was 150 dirs × 1,000 random 2 KiB files (≈ 293 MiB, 150k blobs). Uploads were throttled with `--limit-upload 2048`.

1. **`kill -9` after 100 s.** 13 packs had been uploaded, 1 index written (7 packs, 56,196 blobs: the 50k-blob trigger), 0 snapshots, and 1 lock was left behind. `check` was then refused ("repository is already locked") until `unlock`. The re-run printed `no parent snapshot found, will read all files`, read all 150,000 files and added 254 MiB (raw data plus trees). Afterwards `check` reported 4 unreferenced packs, and `prune` removed **65 MiB of orphaned uploads**.
2. **SIGINT after 40 s,** before any index trigger. Exit code 130, lock removed, **6 packs (98 MB) uploaded with 0 index files**. All of that work was wasted.
3. **Growing set.** Backed up `data/d0[0-4]*` (50k files) as a snapshot, then ran `backup data` with `--dry-run`:
   - with the default `--group-by host,paths`: "no parent snapshot found", 150,000 new files;
   - with `--parent <id>`, or with `--group-by host`: "using parent snapshot", **100,000 new, 50,000 unmodified**.

   Parent matching works by path inside the tree, so a snapshot of a subset is a usable parent for a superset.

## Implications for the map

**Supervisor daemon (launchd):**
- **Get to a first snapshot early, then grow it.** Rather than one 4-week `backup /`, run a sequence of cumulative backups. Each covers more of the tree (for example by top-level directory, or by size budget) and finishes with a real snapshot. Pass an explicit `--parent <previous id>` (not `latest`; default grouping won't match a changed path set) and tag it, e.g. `partial`.
  - Each step then re-stats the covered part but only reads new files.
  - An interruption costs at most the current step's unindexed 10 minutes, plus a re-read of the current step's files.
  - This is the key "no fork" design, verified in experiment 3. Size steps so a step can finish between likely interruptions.
- **Pause with SIGSTOP/SIGCONT, not kill.** A stopped process loses nothing. After resume, restic checks that its lock still exists (0.16.0+) and dead connections are retried. Killing always discards up to 10 minutes of uploads.
  - When the network goes away, the supervisor should pause restic before the 15-minute retry window runs out, and resume it on network-up, to avoid a fatal abort.
  - **Open question:** can restic stay stopped for days without trouble (S3 credential expiry, lock age)? Lock refresh says yes as long as nobody runs `unlock`. This needs a prototype on a real Mac with S3.
- **Watch bytes, not time.** Run `--json` and treat no increase in `bytes_done` / uploaded bytes for N minutes as a stall (the #22034 class). Then SIGTERM and restart. A restart costs a re-read of the current step only.
- **Always pass the right flags:** `--exclude-cloud-files`, `--no-cache` (or a small, managed `--cache-dir`), `TMPDIR` on a volume with space. Optionally set `--read-concurrency` higher on NVMe. Never run `prune` while partial steps are in flight.

**Read-only client:**
- It **must never run `unlock`, `prune` or `check`**, because removing the sleeping backup's lock aborts the backup on wake. Plain read commands and `--no-lock` are safe alongside a running `backup`.
- "View the full backup while the first backup runs" can only mean "view the latest *partial* snapshot". The growing-set design gives the client something to show. Uploaded data without a snapshot is visible only through `recover`-style tree scanning. That is not worth building, but note it.

**Low-disk / low-RAM goals:**
- **Disk:** achievable with flags: `--no-cache`, `--exclude-cloud-files`, and about 150 MiB of temp space. The cost of `--no-cache` is more S3 GETs for parent trees on later steps. **Decision needed:** `--no-cache` versus a bounded cache that the supervisor prunes.
- **RAM:** not boundable with flags. It scales with the repository blob count. `GOGC` lower than 50 trades CPU for RAM. **Question for another ticket:** expected blob count for the user's Mac. Many small files dominate; larger `--pack-size` does not help, because blobs, not packs, drive the index.

**Upstream versus fork:**
- Everything above works with a stock v0.19.1.
- Worth following, or contributing to upstream instead of forking:
  - [#2960](https://github.com/restic/restic/issues/2960) (flush index and save an interrupted snapshot on SIGINT; the maintainer invites an attempt);
  - [#2280](https://github.com/restic/restic/issues/2280) / [#3230](https://github.com/restic/restic/pull/3230) (resume file);
  - [#22048](https://github.com/restic/restic/pull/22048) (silent S3 stalls).
- **New question:** should the map plan an upstream PR for "flush index on SIGTERM"? It is the smallest change that would cut the per-interruption loss to near zero.

**Consistency:** a weeks-long first backup is never point-in-time. **Decision needed:** accept the drift (later runs heal it), or have the supervisor back up from APFS local snapshots. Snapshots change the paths seen by restic and need Full Disk Access orchestration ([forum 4232](https://forum.restic.net/t/4232/9)), which belongs to the macOS ticket.
