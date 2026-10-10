# Research: why restic uses so much RAM and local disk, and what can shrink it

Ticket: #4 (part of map #1). Baseline: **restic v0.19.1** (latest release, 2026-07-05, commit `6aa3a51`). All source links point at the `v0.19.1` tag unless marked otherwise. "Unreleased" means merged on `master` after v0.19.1.

## TL;DR

- **RAM grows with the number of blobs in the whole repository.** Every `backup` loads the complete index into memory at about 68 bytes per blob (live heap, measured), plus Go GC headroom. On top of that sit per-core working buffers (≈8 MiB chunks × concurrency), the S3 client holding each pack being uploaded in RAM, and per-directory tree building that blows up on very wide directories and xattr-heavy macOS directories. For a typical large Mac, expect roughly **0.5–1 GB RSS on v0.19.1**. It reaches many GB only for very large or shared repositories, or for million-entry directories. The 2017–2021 "10–30 GB" reports were mostly older versions (≤0.9.x), shared multi-TB repositories, or wide directories.
- **Local disk has two separate consumers.** (1) The **persistent cache** (`~/Library/Caches/restic`) holds all index files, snapshot files and every **tree (metadata) pack**. It has **no size limit** (upstream #4325 and #2748 are still open). (2) **Temporary pack files** in `$TMPDIR` take about `(4 open packers + S3 connections + 1) × pack size`, which is ~100–180 MiB at defaults. On Unix they are unlinked right after creation, so the space is freed even after a crash.
- **When the disk fills, the backup aborts.** A failed cache write fails the command (deliberately, since v0.16.0, #4130/#4166); a failed temp-pack write fails it too. Earlier snapshots stay intact. No snapshot is written for the interrupted run.
- **What shrinks it today, with no fork:** `--no-cache`, which leaves only temp packs on disk and costs one index download per start. It is cheap for an initial backup that has no parent, but slow for incremental backups. Also: `TMPDIR`/`RESTIC_CACHE_DIR` on a volume with room, `GOMAXPROCS=2` (≈ halves RSS, ~20% slower in my test), the default 16 MiB `--pack-size` (bigger packs cost more RAM *and* temp disk), and `-o s3.connections`. Two flags don't help: `GOMEMLIMIT` is only a soft limit (it cut RSS 335→192 MB but ran 3.7× slower), and `--read-concurrency 1` did nothing for RSS.
- **Verdict on the user's experience:** it was partly real limits and partly defaults/setup. RAM got 2–4× better across 0.10 / 0.14 / 0.16, but scaling with blob count is fundamental and still open (#1988, #2446). The disk failure is still possible on v0.19.1 when the cache and `TMPDIR` sit on a nearly full system volume, but it can be avoided with flags. Unbounded cache growth is a real, open upstream gap, not user error.

## 1. What drives RAM during `backup`

### 1.1 The in-memory index: O(all blobs in the repo)

- `backup` calls `repo.LoadIndex` before it starts ([cmd/restic/cmd_backup.go#L570](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L570)). That downloads, decrypts and parses **every** index file and merges them into one in-memory `MasterIndex` ([internal/repository/index/master_index.go#L282-L335](https://github.com/restic/restic/blob/v0.19.1/internal/repository/index/master_index.go#L282-L335)).
- Each blob is an `indexEntry` of 32-byte ID + `next` + `packIndex int` + three `uint32` fields ([indexmap.go#L246-L253](https://github.com/restic/restic/blob/v0.19.1/internal/repository/index/indexmap.go#L246-L253)), stored in a chained hash table with pointer-only buckets ([indexmap.go#L11-L41](https://github.com/restic/restic/blob/v0.19.1/internal/repository/index/indexmap.go#L11-L41)).
- **Measured (tiny experiment, §6):** 67.8–67.9 bytes of live heap per blob at 1 M and 4 M blobs. restic sets `GOGC=50` by default unless the user overrides it ([cmd/restic/main.go#L128-L134](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/main.go#L128-L134); changelog 0.16.0 #3328, [PR #4353](https://github.com/restic/restic/pull/4353)), so RSS for the index is roughly 1.5× that, about **~100 B per blob**.
- Blobs written *during* the backup are added to the same in-memory index and never evicted ([master_index.go#L148-L172](https://github.com/restic/restic/blob/v0.19.1/internal/repository/index/master_index.go#L148-L172)). A long first backup's RAM therefore grows over its lifetime, and every restart after an interruption reloads everything uploaded so far.
- What counts is the **blob count**, not the TB: one blob per small file (files smaller than the minimum chunk) plus one per ~1 MiB average chunk of large files, plus one tree blob per directory. A Mac with 3 M files and 2 TB of large-file data is ≈5 M blobs, so ≈340 MB live index and ≈0.5 GB RSS for the index alone *(estimate from the measured per-blob figure)*.
- **Unreleased:** [PR #21937](https://github.com/restic/restic/pull/21937) (merged 2026-07-15, after v0.19.1) shrinks an entry from 64 to 56 bytes. Its author reports ~13 M blobs going from 814→713 MB live index and 1252→1129 MB RSS.
- **Open:** [#1988 "reduce index memory usage"](https://github.com/restic/restic/issues/1988) (since 2018). fd0 explained why mmap'ing index files would not help: the data must be decrypted and parsed into an in-memory structure anyway ([comment](https://github.com/restic/restic/issues/1988#issuecomment-450629363)). The maintainers' standing advice for very large shared repositories is to split them ([forum](https://forum.restic.net/t/restic-uses-more-than-4gb-ram-on-14gb-backup-than-crashes/4584)).

### 1.2 Working buffers: scale with CPU cores

- File chunk buffers are `chunker.MaxSize` (8 MiB) each, from an unbounded `sync.Pool` ([file_saver.go#L40](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/file_saver.go#L40), [buffer.go](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/buffer.go)). How many are live depends on concurrency:
  - `--read-concurrency` (default 2) file readers;
  - `GOMAXPROCS + read-concurrency` tree savers ([archiver.go#L154-L172](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/archiver.go#L154-L172));
  - up to `2 + GOMAXPROCS` blob-saver goroutines ([repository.go#L570](https://github.com/restic/restic/blob/v0.19.1/internal/repository/repository.go#L570)).
- Each saved blob is compressed into a new buffer, encrypted into another, then **decrypted and decompressed again for verification** ([repository.go#L378-L421](https://github.com/restic/restic/blob/v0.19.1/internal/repository/repository.go#L378-L421), [L423-L446](https://github.com/restic/restic/blob/v0.19.1/internal/repository/repository.go#L423-L446)). `--no-extra-verify` skips that last copy, at the cost of corruption checks ([tuning docs L66-L77](https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst#L66-L77)).
- The docs say limiting `GOMAXPROCS` "can slightly reduce the memory usage" ([tuning docs L47-L53](https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst#L47-L53)). In my test the reduction was large: 8 cores 297–335 MB, `GOMAXPROCS=2` 163 MB, `GOMAXPROCS=1` 120 MB (§6). Current Apple Silicon Macs have 8–16+ cores, so the default is the worst case.

### 1.3 S3 uploads hold whole packs in RAM

- restic's S3 `Save` calls minio-go `PutObject` with `SendContentMd5: true`, `PartSize: 200 MiB`, and wraps the reader in `io.NopCloser`, which hides `Seek`/`ReadAt` ([internal/backend/s3/s3.go#L290-L311](https://github.com/restic/restic/blob/v0.19.1/internal/backend/s3/s3.go#L290-L311)).
- Packs are at most 128 MiB, below the 200 MiB part size, so minio-go always takes the single-PUT path ([minio-go v7.1.0 api-put-object.go#L376-L378](https://github.com/minio/minio-go/blob/v7.1.0/api-put-object.go#L376-L378)). For a non-seekable reader with MD5 requested, that path does `buf := make([]byte, size)` and reads the whole object into memory ([api-put-object-streaming.go#L692-L721](https://github.com/minio/minio-go/blob/v7.1.0/api-put-object-streaming.go#L692-L721)).
- So uploads add **≈ connections × pack size** of RAM: 5 × 16 MiB = 80 MiB by default, or 640 MiB with `--pack-size 128`. The tuning docs hint at this ("depending on the backend the memory usage can also increase by a similar amount", [L105-L114](https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst#L105-L114)). *(Code reading; I did not test against a real S3 endpoint.)*

### 1.4 Directory trees: wide directories and macOS xattrs

- A directory's whole tree, a futureNode per entry plus the serialised JSON tree blob, is held in memory until the directory is finished ([tree_saver.go#L46-L90](https://github.com/restic/restic/blob/v0.19.1/internal/archiver/tree_saver.go#L46-L90)).
- [#2446](https://github.com/restic/restic/issues/2446) (**open**, since 0.9.5): one million empty files in one directory took ~2.8 GB peak.
  - 0.14.0 cut this by up to 30% ([PR #3773](https://github.com/restic/restic/pull/3773)).
  - Chunked trees are the planned real fix ([maintainer](https://github.com/restic/restic/issues/3643)); the preparatory [PR #5613](https://github.com/restic/restic/pull/5613) is in 0.19.0 and [#21943](https://github.com/restic/restic/pull/21943) is still open.
  - Three open contributor PRs against v0.19.1 report one million entries going from 1248 MB RSS down to 773 MB ([#22080](https://github.com/restic/restic/pull/22080)), 603 MB ([#22081](https://github.com/restic/restic/pull/22081)) or 208 MB ([#22082](https://github.com/restic/restic/pull/22082), draft, spills the tree to a temp file). None has been reviewed yet.
- **Mac-specific:** [#3643](https://github.com/restic/restic/issues/3643) (**open**, 0.12.1). Large extended attributes under `~/Library/Containers` produced **~286 MB tree blobs**. That inflates both RAM and the cache, and dedups badly because a tree blob is one unit.
  - [PR #4486](https://github.com/restic/restic/pull/4486) (v0.16.1) puts oversized blobs into their own packs, so they no longer drag neighbours into the cache. It does not make them smaller.

### 1.5 GC knobs

- `GOGC`: restic defaults to 50 and respects a user-set value ([main.go#L128-L134](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/main.go#L128-L134)). Maintainers have long suggested `GOGC=20` or lower for small machines ([#1396](https://github.com/restic/restic/issues/1396), [#2519](https://github.com/restic/restic/issues/2519), [#3374](https://github.com/restic/restic/issues/3374)). It trades CPU for headroom and cannot shrink the live index.
- `GOMEMLIMIT`: restic does not set it, but the Go runtime honours the env var as a **soft** limit ([Go GC guide](https://go.dev/doc/gc-guide#Memory_limit)). Measured: a 100 MiB limit gave 192 MB RSS (vs 335 MB) at 3.7× the run time (§6). [#21790](https://github.com/restic/restic/issues/21790) (0.18.1) shows `GOMEMLIMIT=500MiB` failing to contain runaway growth. It is a GC-pressure knob, not a cap.

### 1.6 Judging the "enormous RAM" reports

| Report | Version | Size | RAM | Cause |
|---|---|---|---|---|
| [#1171](https://github.com/restic/restic/issues/1171) | 0.7.1 | 1.2 TB | 3 GB | old index |
| [#2519](https://github.com/restic/restic/issues/2519) | 0.9.5 | 1.4 TB | 10+ GB | old index |
| [forum 2024](https://forum.restic.net/t/memory-usage-oom-etc-on-a-big-repository/8758) | 0.17.3 | 1.2 TB, ~150 M blobs (maintainer estimate) | up to 30 GB | blob count; ~3.5 GB after cleanup |
| [forum 2021](https://forum.restic.net/t/restic-uses-more-than-4gb-ram-on-14gb-backup-than-crashes/4584) | 0.9.6/0.12.1 | "14 GB backup" into a 725 GB shared repository | >4 GB | ~8 GB index from the shared repository |
| [HN 2025](https://news.ycombinator.com/item?id=44217132) | not stated | not stated | "dozens of GB" | unknown |
| [#5433](https://github.com/restic/restic/issues/5433) | 0.18.0 | — | macOS session crash | not a restic memory bug (reporter fixed OS config) |

Changelog milestones: index memory down up to 50% in 0.10.0 (#2781), wide directories down 30% in 0.14.0 (#3773), GC-friendly index plus `GOGC=50` down up to 25% in 0.16.0 (#3328) ([CHANGELOG.md](https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md)). Conclusion: on current versions, multi-GB backups mean a huge blob count (tens of millions or more) or a pathological directory. The user's Mac may still have such directories (Mail, `~/Library/Containers`, `node_modules`, photo libraries), so this needs measuring, not assuming.

## 2. What drives local disk use

### 2.1 Persistent cache: no size limit

- **Location:** `$RESTIC_CACHE_DIR`, else `os.UserCacheDir()/restic`, which is `~/Library/Caches/restic` on macOS ([internal/backend/cache/dir.go#L16-L28](https://github.com/restic/restic/blob/v0.19.1/internal/backend/cache/dir.go#L16-L28); [manual L439-L474](https://github.com/restic/restic/blob/v0.19.1/doc/manual_rest.rst#L439-L474)). If the environment has no `HOME`, restic **exits with an error** (manual, same section). [#4775](https://github.com/restic/restic/issues/4775) is a systemd unit hitting exactly that, and a launchd daemon will too.
- **Contents:** all index files, all snapshot files, and **every pack marked metadata (tree packs)** ([cache/backend.go#L50-L58](https://github.com/restic/restic/blob/v0.19.1/internal/backend/cache/backend.go#L50-L58)). New tree and index files are written to the cache **at upload time** ([backend.go#L61-L93](https://github.com/restic/restic/blob/v0.19.1/internal/backend/cache/backend.go#L61-L93)), so a first backup fills the cache with all metadata it creates. Missing files are re-downloaded on demand ([backend.go#L153-L197](https://github.com/restic/restic/blob/v0.19.1/internal/backend/cache/backend.go#L153-L197)), so the cache is safe to delete.
- **Size:** index ≈ 46 B per blob on disk; trees ≈ 47 B per file without xattrs (measured, §6). macOS metadata (xattrs, ACLs, resource forks) can make trees far larger (#3643). Reports:
  - fd0 has seen caches of **3–10% of data** ([forum](https://forum.restic.net/t/massive-cache-size/2352)).
  - The extreme ones are almost always "never pruned" repositories: 37 GB/1.2 TB growing to 240 GB/1.6 TB in that thread; 124 GB on 264 GB with 220 snapshots, shrinking to 8 GB after pruning ([forum](https://forum.restic.net/t/large-cache-size/6058)); 49–50 GiB caches for ~250 GB repositories ([#3552](https://github.com/restic/restic/issues/3552)).
- **No limit or LRU:** [#4325 "limit the size of cache"](https://github.com/restic/restic/issues/4325) (**open**, 0.14.0) and [#2748](https://github.com/restic/restic/issues/2748) (**open**, 0.9.6). `--cleanup-cache` only deletes *other* repositories' cache dirs older than 30 days ([global.go#L422-L461](https://github.com/restic/restic/blob/v0.19.1/internal/global/global.go#L422-L461), [cache.go#L157-L158](https://github.com/restic/restic/blob/v0.19.1/internal/backend/cache/cache.go#L157-L158)). It never trims the active repository's cache.

### 2.2 Temporary pack files

- Each pack is assembled in a temp file `restic-temp-pack-*` in `$TMPDIR` (Go's `os.TempDir`, which falls back to `/tmp`). On Unix it is **unlinked right after creation**, so it is invisible to `ls` and its space is freed when the process exits, even on a crash ([internal/fs/file_unix.go#L18-L29](https://github.com/restic/restic/blob/v0.19.1/internal/fs/file_unix.go#L18-L29), [packer_manager.go#L202-L218](https://github.com/restic/restic/blob/v0.19.1/internal/repository/packer_manager.go#L202-L218)). Old reports of leftover temp packs ([#611](https://github.com/restic/restic/issues/611), [#948](https://github.com/restic/restic/issues/948)) predate this.
- **Number of temp files at once:**
  - Since v0.18.0, each blob type (tree and data) spreads blobs randomly over **2** open packers, to resist chunking attacks ([packer_manager.go#L42](https://github.com/restic/restic/blob/v0.19.1/internal/repository/packer_manager.go#L42), [L162-L189](https://github.com/restic/restic/blob/v0.19.1/internal/repository/packer_manager.go#L162-L189); commit `62453f9`).
  - Full packs go through an unbuffered queue to `connections` uploaders, each holding its temp file until the upload is done ([packer_uploader.go#L24-L59](https://github.com/restic/restic/blob/v0.19.1/internal/repository/packer_uploader.go#L24-L59)).
  - Worst case is therefore about **(4 open + 5 uploading + up to 2 blocked) × 16 MiB ≈ 176 MiB** at defaults. The docs' rule of `pack size × (connections + 1)` ([tuning docs L105-L114](https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst#L105-L114)) predates the two-packer change and understates this *(code reading)*.
  - Packs can also overshoot the target by up to one chunk, and oversized blobs get a pack of their own ([#4412](https://github.com/restic/restic/issues/4412)).
- **Pack size:** `--pack-size` / `RESTIC_PACK_SIZE` accepts 4–128 MiB, default 16 ([repository.go#L28-L30](https://github.com/restic/restic/blob/v0.19.1/internal/repository/repository.go#L28-L30); [PR #3731](https://github.com/restic/restic/pull/3731), 0.14.0). Larger packs raise temp disk, S3-upload RAM (§1.3) and SSD writes ([tuning docs L116-L120](https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst#L116-L120)). Smaller packs mean more S3 objects (2 TB / 4 MiB ≈ 500 k).
- On macOS, `$TMPDIR` for a user session is `/var/folders/...` and `/tmp` is `/private/tmp`. Both are on the Data volume with the user's files, so a nearly full disk hits the cache and temp packs together.
- `--cache-dir` / `RESTIC_CACHE_DIR` does **not** move temp packs. `TMPDIR` must be set separately ([forum: 20 TB of SSD writes](https://forum.restic.net/t/restic-uses-tbw-on-local-drive/8967); [#4813](https://github.com/restic/restic/issues/4813), [#5572](https://github.com/restic/restic/issues/5572) for Windows' `TMP`).

### 2.3 What happens when the disk fills mid-backup

- **Cache write fails:** `Backend.Save` uploads the pack to S3 first, then writes it to the cache. If the cache write fails, it **returns the error** ([backend.go#L74-L90](https://github.com/restic/restic/blob/v0.19.1/internal/backend/cache/backend.go#L74-L90)), `savePacker` fails before `StorePack` indexes the pack ([packer_manager.go#L262-L277](https://github.com/restic/restic/blob/v0.19.1/internal/repository/packer_manager.go#L262-L277)), and the backup is cancelled.
  - This is deliberate since **0.16.0**: "If the cache directory was removed or ran out of space … the currently running command is instead canceled" (changelog #4130, [PR #4166](https://github.com/restic/restic/pull/4166)). Before that, restic limped on, drastically slower.
  - The uploaded-but-unindexed pack becomes an orphan that `prune` removes later.
- **Temp-pack write fails:** the write error from `packer.Add`/`Finalize` comes back through `SaveBlob` and the backup aborts. QNAP's 32–64 MB RAM `/tmp` killed a 3 TB initial backup after 130 GiB ([#1440](https://github.com/restic/restic/issues/1440)).
- **After the abort:** temp space is freed at exit (unlinked files), earlier snapshots are intact (backup only adds data; [#1153](https://github.com/restic/restic/issues/1153)), and **no snapshot is written for the run**.
  - Packs already uploaded *and* indexed are deduplicated on the next run.
  - The index is written about every 10 minutes or 50 k blobs ([index.go#L95-L124](https://github.com/restic/restic/blob/v0.19.1/internal/repository/index/index.go#L95-L124)), so a hard kill loses at most the most recent stretch of uploads. Ticket #2 covers resume behaviour in depth.
- I did not run a real ENOSPC test (no root for a small loop/tmpfs mount). The above is from code reading plus the changelog.

### 2.4 `--no-cache`: what it costs

- **What it does:** no cache is opened at all ([global.go#L329-L331](https://github.com/restic/restic/blob/v0.19.1/internal/global/global.go#L329-L331)). Index files are downloaded from S3 on every start (≈46 B per blob, so ~230 MB for 5 M blobs). Tree blobs are fetched with one ranged GET each.
- **First backup:** there is no parent snapshot, so no trees are read, and `--no-cache` costs almost nothing. In my local-backend test, RSS and run time were identical with and without the cache (§6).
- **Incremental backups:** with a parent snapshot, restic loads the parent tree for each directory, roughly one S3 round trip per directory, mostly one after another. Users report **2 minutes → 3+ hours** ([#2748 comment](https://github.com/restic/restic/issues/2748#issuecomment-878152006), B2) and 1:30 → 2:15:50 ([#4775](https://github.com/restic/restic/issues/4775)).
- `--no-cache` does **not** remove temp packs ([#4813](https://github.com/restic/restic/issues/4813)).

## 3. Flags and env vars that reduce footprint (v0.19.1)

| Knob | Effect on RAM | Effect on local disk | Cost |
|---|---|---|---|
| `--no-cache` | none measurable | removes persistent cache (~1–5% of data, unbounded) | index download every start; very slow incrementals |
| `RESTIC_CACHE_DIR` / `--cache-dir` | — | moves cache (e.g. to an external or roomy volume) | — |
| `TMPDIR` | — | moves temp packs | — |
| `--pack-size N` (4–128 MiB, default 16) | S3: ≈ connections × N | ≈ (5 + connections) × N | small N → more objects; large N → more RAM, temp disk and SSD writes |
| `-o s3.connections=N` (default 5) | −N × pack size | −N × pack size | slower upload on high-latency links |
| `GOMAXPROCS=2` | **large** (335→163 MB in test) | — | ~20% slower in my test (26.7 s vs 22.1 s) |
| `GOGC=20…50` (default 50) | modest | — | more CPU |
| `GOMEMLIMIT` | soft cap only | — | GC thrash (3.7× slower at 100 MiB) |
| `--read-concurrency` (default 2) | none measured at 1 | — | — |
| `--no-extra-verify` | one less blob copy per in-flight blob | — | loses pre-upload corruption check |
| `--compression` | encoder state only | — | — |

## 4. Upstream issues and PRs to track

| # | Kind / state | Topic |
|---|---|---|
| [#1988](https://github.com/restic/restic/issues/1988) | issue, open | index memory scales with blobs |
| [#2446](https://github.com/restic/restic/issues/2446) | issue, open | wide-directory memory; chunked trees planned |
| [#3643](https://github.com/restic/restic/issues/3643) | issue, open | macOS large xattrs → huge tree blobs (RAM + cache) |
| [#4325](https://github.com/restic/restic/issues/4325), [#2748](https://github.com/restic/restic/issues/2748) | issues, open | cache size limit / LRU |
| [#4371](https://github.com/restic/restic/issues/4371) | issue, open | larger max pack size (would raise temp disk) |
| [#4702](https://github.com/restic/restic/issues/4702) | issue, open | temp packs hit disk (Windows) |
| [#21937](https://github.com/restic/restic/pull/21937) | PR, merged after v0.19.1 | −8 B per index entry |
| [#21943](https://github.com/restic/restic/pull/21943) | PR, open | blob-sequence reader/writer (chunked-tree groundwork) |
| [#22080](https://github.com/restic/restic/pull/22080), [#22081](https://github.com/restic/restic/pull/22081), [#22082](https://github.com/restic/restic/pull/22082) | PRs, open | wide-directory RAM 1248 → 773 / 603 / 208 MB |

## 5. Verdict per user complaint

- **"RAM use was enormous."** Partly fixed, partly fundamental. Versions before 0.10/0.16 used 2–4× more. On v0.19.1 RAM is ≈100 B per repository blob plus ≈20–40 MB per core plus connections × pack size, with spikes on huge directories or xattr-heavy macOS directories (still open upstream). Defaults leave easy wins on the table on a many-core Mac (`GOMAXPROCS`).
- **"Local disk use so large on a nearly full disk that the backup failed."** Still possible on v0.19.1, because the cache and `TMPDIR` default to the system volume, the cache has no cap, and a full cache aborts the run. Avoidable with flags: `--no-cache` for the initial backup plus `TMPDIR`/cache on a volume with room. A cache cap is an **open upstream gap**, not user error.
- **"Almost zero local cache."** Achievable for the initial backup with `--no-cache`, leaving ~100–180 MiB of transient temp packs. **Not** achievable for fast incremental backups without either a cache (metadata-sized, ~1–5% of data) or a fork or upstream change.

## 6. Tiny experiments (in `/tmp`, not shipped)

All runs: restic v0.19.1 built from the tag (`go build`, go1.26.3, linux/arm64, 8 cores), **local** repository backend, `/usr/bin/time` max RSS. They are indicative only: not macOS, and not S3 (so the §1.3 upload buffering is absent).

- **Index heap per blob:** a throwaway test in `internal/repository/index` adding random blobs to a `MasterIndex` gave 1 M blobs → 64.7 MiB (67.9 B/blob) and 4 M blobs → 258.7 MiB (67.8 B/blob).
- **End-to-end:** 300 000 small random files (200 B–8 KB) in 1 000 directories plus 4 × 256 MiB random files. That is 2.8 GB on disk, 301 678 blobs, a 2.2 GiB repo and 6 index files.

| Run | Max RSS | Wall time |
|---|---|---|
| first backup (no parent) | 297 MB | 29.5 s |
| second backup (parent, cache) | 167 MB | 5.6 s |
| `--force` (re-read all, full index) | 335 MB | 22.1 s |
| `--force --no-cache` | 336 MB | 22.0 s |
| `--force`, `GOMAXPROCS=1` | 120 MB | 36.5 s |
| `--force`, `GOMAXPROCS=2` | 163 MB | 26.7 s |
| `--force --read-concurrency 1` | 303 MB | 26.6 s |
| `--force`, `GOMEMLIMIT=100MiB` | 192 MB | 81.3 s |
| `snapshots` | 69 MB | 0.7 s |

Cache after the first backup: **28 MB** in total (14 MB index, 14 MB tree packs).

## Implications for the map

**Supervisor daemon**
- It **must set the environment explicitly**:
  - `RESTIC_CACHE_DIR` (a launchd daemon may have no `HOME`, and restic then exits);
  - `TMPDIR` (to a directory it owns and can measure);
  - `GOMAXPROCS=2` (≈ halves RSS);
  - `RESTIC_PACK_SIZE=16` (keep the default; explicit for reproducibility);
  - `-o s3.connections` (tune between RAM and upload speed).
- It **must watch free disk space itself**. restic has no cap and aborts on ENOSPC. The supervisor should stop restic cleanly (SIGINT) *before* the volume fills, reserving about `(5 + connections) × pack size` plus the cache growth headroom, and resume later. That turns "the backup failed" into "the backup paused".
- It should treat RSS as a monitored metric. It grows with blobs uploaded so far, so it is highest late in a 4-week first backup. A pre-flight **inventory scan** (file count, largest directory, xattr-heavy directories such as `~/Library/Containers`) can predict RAM and cache size and suggest excludes.
- **Cache policy:** run the initial backup with `--no-cache`, which is near-zero persistent disk and costs nothing without a parent. Enable the cache only once a first snapshot exists. Because the cache is safe to delete, the supervisor could also prune `data/` (tree packs) after each run if disk is tight, accepting re-downloads.

**Read-only client**
- To browse it needs only **tree blobs**. It still has to download and decrypt all index files (they mix types), but it can **drop data-blob entries while parsing**, keeping roughly one entry per directory instead of one per chunk. That is a large RAM win over restic's full `MasterIndex`, and an argument for our own pure-Go reader rather than shelling out to `restic`.
- It needs its own cache policy: trees can be fetched lazily with ranged GETs, and a bounded LRU on disk is easy to build outside restic.

**Low-disk / low-RAM goals**
- **No fork is needed** to reach "low" for the initial backup:
  - `--no-cache`, `TMPDIR`, a default or smaller pack size and `GOMAXPROCS` give ~0.2–1 GB RSS and ~100–200 MiB transient disk for a typical large Mac.
- Fundamental limits remain:
  - RAM is O(repository blobs);
  - wide or xattr-heavy directories spike (open upstream; PRs #22080–#22082 pending);
  - there is no cache cap for incremental backups.
- **Recommend** tracking these upstream, not forking. Revisit if the inventory shows directories with hundreds of thousands of entries or ~100 MB+ trees.

**New questions / decisions surfaced**
1. **Inventory first:** how many files and directories does the user's Mac have, what is the largest directory, and how big are xattrs under `~/Library`? This drives every RAM and cache estimate here. (Suggest a small prototype ticket: a pure-Go scan that reports these.)
2. **Decision:** initial backup with `--no-cache`, cache enabled afterwards (or a supervisor-managed bounded cache). Needs confirming in grilling.
3. **Decision:** should the supervisor own a disk-space floor and pause restic below it? (Recommended: yes.)
4. **Open:** should the user's repository be dedicated to this Mac? (A shared repository multiplies index RAM on every client, per the forum reports.)
5. **Open:** for S3, is `-o s3.connections=2–3` acceptable upload throughput on the user's link? It saves ~16 MiB of RAM and ~16 MiB of temp disk per connection at default pack size.
