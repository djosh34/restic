# APFS and restic's many-files cost

## TL;DR

- **There are ways around repeated full walks, but no stock-restic switch that does it.** Restic **v0.19.1** still visits every included file. `--no-scan` removes the extra progress scan, not the backup walk. `--files-from` plus `--parent` does not merge unchanged files into the new snapshot. Two relevant upstream PRs remain unmerged. [Sources: tuning docs][tuning], [walk source][walk], [PR #4469][changed-pr], [PR #3405][merge-pr].
- **A change journal plus a new snapshot writer is a real optimization, not a proven lossless change oracle.** The standard restic format allows unchanged subtree reuse without a per-file local database. But Apple calls FSEvents history advisory and recommends periodic full sweeps. No supported public snapshot-to-snapshot changed-path API was found. [Sources: format][format-trees], [FSEvents contract][fsevents], [snapshot API][snapshot-api].
- **Sparsebundles genuinely reduce the outer file count.** At 8 MiB bands, a 100 GiB virtual image has 12,800 band positions, rather than millions of restic file nodes. But it needs consistent image capture, can amplify reads, and turns inner-file browsing into a separate APFS recovery problem. Raw internal-volume reads are not a supported plaintext shortcut. [Sources: `hdiutil`][hdiutil], [`diskutil`][diskutil], [restic read loop][file-read].
- **Five million small files are a genuine resource problem, not user error.** Five million distinct small-file blobs alone imply about 300 MiB of index structures before runtime overhead. Tree metadata and macOS xattrs add costs tied to file count and directory shape. `--no-cache` removes the persistent cache, not RAM or temporary upload files. [Sources: index accounting][index], [node format][node], [cache source][cache], [tuning docs][tuning].

Research for [ticket #11](https://github.com/djosh34/restic/issues/11), part of [map #1](https://github.com/djosh34/restic/issues/1). Checked **2026-10-10**. GitHub's latest release was **v0.19.1**, published 2026-07-05. I cloned `https://github.com/restic/restic` into `/tmp/restic-apfs-many-files-v0.19.1`, checked out commit `6aa3a516ce654808a1f28f9fa21e9b7c8e6e90bf`, read its source and CHANGELOG, and built it with Go 1.26.3 on Linux/arm64. Unless another version is named, restic claims below apply to **v0.19.1**, with repository format v2 when discussing compression. [Release][release].

## What stock restic can and cannot skip

### A parent saves file reads, not directory walks

In **v0.19.1**, `saveDir` reads and sorts every name in a directory, then processes every included entry. For an unchanged regular file, restic checks metadata, verifies that the old content blobs are indexed, and reuses their IDs. It still constructs a fresh metadata node. For a directory it loads the old subtree and descends again. There is no unchanged-directory shortcut based on APFS snapshots or directory timestamps. [Source: `saveDir`, `save`, `fileChanged`][walk].

`--no-scan` is worthwhile because it disables the separate progress-estimation traversal. It does **not** disable the traversal above. `--skip-if-unchanged` compares the completed root tree with the parent after that work; it avoids an identical snapshot record, not the work needed to discover it. Higher read concurrency or lower `GOMAXPROCS` tune constants, not the number of visited files. [Sources: tuning docs][tuning], [snapshot construction][snapshot-write].

### A changed-path list produces a partial snapshot

In **v0.19.1**, `--files-from`, `--files-from-verbatim` and `--files-from-raw` select backup targets. `--parent` supplies old metadata/content for matching paths. It does not inherit paths omitted from the target list. Including a directory selects its contents recursively, so adding the old root to the list puts the full walk back. `rewrite` filters existing snapshots or changes their metadata; it does not merge new source files into them. [Sources: target-list docs][files-from], [snapshot construction][snapshot-write], [rewrite command][rewrite].

**Tiny experiment, not a Mac performance benchmark:** using the source-built **v0.19.1** binary and a new local repository, I backed up a directory with files `a` and `b`, changed only `b`, then ran:

```text
restic backup --no-cache --no-scan --parent <first-snapshot-id> \
  --files-from-verbatim <list-containing-only-the-absolute-path-to-b>
```

`restic ls latest` listed `b` and its ancestor directories, but no `a`. `restic check --no-cache` passed: the second snapshot is valid, just partial. This matches the source and the exact missing feature described in [PR #3405][merge-pr]. Experiment script and disposable repository stayed under `/tmp`.

As of this research, **[issue #1502][watch-issue]**, **[PR #4469][changed-pr]** and **[PR #3405][merge-pr]** are open. PR #4469 adds explicit changed-file lists and reuses unchanged subtrees; PR #3405 adds parent merging for file-list backups. Neither feature is in **v0.19.1**. A filesystem watcher around the unmodified CLI therefore cannot silently turn delta-only runs into complete snapshots. In particular, replaying partial snapshots at restore time cannot distinguish a deleted file from an unchanged omitted file. [Same upstream discussion][watch-issue].

**Important clarification to the map:** a *cumulatively growing target set* can create increasingly complete snapshots with stock **v0.19.1**. A *list containing only the next batch* cannot. Growing the target set also revisits the already included files. That is a valid first-backup strategy, but not a solution to the many-files walk cost. [Sources: target selection][files-from], [walk][walk], [prior ticket #2](https://github.com/djosh34/restic/issues/2).

## Writing a complete standard-format snapshot ourselves

**Yes, technically.** A **v0.19.1** snapshot names a root tree. Tree entries name file-content blobs or other tree blobs. These are content-addressed objects. A new root can reference old unchanged subtrees directly; it need not copy them or retain a chain of older snapshot records for restore. Stock restic can read and restore that root if all referenced objects and metadata obey the standard format. This is an inference from the documented format, not a proposed format extension. [Sources: snapshots and trees][format-trees], [reachability invariants][ordering].

A plausible writer would:

1. Pin an explicit parent snapshot and a source-volume identity.
2. Rescan dirty directories and reconstruct their entries, including deletions, renames, type changes and directory metadata. Keep old subtree IDs outside the dirty region.
3. Write replacement trees up the affected ancestor paths. An affected directory still requires reading/rebuilding its whole tree blob in the current format; a single enormous flat directory remains expensive.
4. Upload packs, then indexes, then the new complete snapshot. Only after that acknowledge the matching baseline/dirty work; notification ingestion can advance separately while retaining that work. Protect this operation against prune with the normal writer locking protocol.

These steps are a **design proposal** based on the [v0.19.1 tree format][format-trees], [current whole-blob tree loading][tree-load], [publication ordering][ordering] and [backup's append lock][backup-open]. A read-only client may avoid locks; a new writer must not copy that policy blindly.

This can keep local journal storage proportional to **changed directories**, rather than store a record for every file. The parent trees in S3 remain the full inventory. A capped dirty-directory set can collapse to a dirty ancestor or a single “rescan the volume” marker. That bounds local state by giving up scan avoidance when activity is too large. It does not remove restic's existing full in-memory blob index if the writer reuses the **v0.19.1** repository implementation. [Sources: remote tree format][format-trees], [full index load in backup][backup-open], [index design][index].

### How much code and risk?

The core shortcut is small: **PR #4469 currently has 147 additions and 41 deletions across three files**. That is evidence of feasibility, not a production estimate. The PR's test and documentation checklist is incomplete and its author explicitly calls out hardlink/device-ID caveats. It does not implement a durable macOS journal or its failure recovery. [PR and diff][changed-pr].

The main risk is **silently reusing stale metadata or content while producing a repository that passes `restic check`**. A structurally valid old subtree is not evidence that it still matches the source. Required tests include missed/coalesced events, journal truncation, daemon crashes at every checkpoint, deleted/moved directories, hardlinks across dirty and clean regions, xattr-only changes, exclusion changes, mount changes, parent loss and concurrent maintenance. This is our risk analysis from [the proposed subtree shortcut][changed-pr] and [restic's structural invariants][ordering].

A practical scope estimate is **a small algorithm change plus a substantial new correctness subsystem**, not “a 147-line wrapper.” There is no defensible production line count from this research. Reusing pinned restic internals reduces crypto/format work, but those packages are `internal/`, not a supported Go SDK. Upstream explicitly warns about unstable interfaces and global state. A separate compatible writer need not fork upstream, but copying/adapting restic internals is still a maintained code derivative. It should not be sold as a maintenance-free way to satisfy “no fork.” A wholly independent writer also owns encryption, key/config handling, chunking, packs, indexes and atomic publication. [Sources: library issue #4406][library], [format specification][format-all].

**Recommendation:** only pursue this after the owner explicitly accepts an engine component beyond a stock-CLI supervisor. Keep the on-disk format unchanged. Use differential restores against stock **v0.19.1**, plus failure-injection tests, as acceptance criteria. Do not treat the open PR as an already supported escape hatch. [Sources: PR status][changed-pr], [format rules][ordering].

## APFS snapshots and change discovery

### Public snapshots are stable views, not a public pathname-diff service

The inspected Apple **XNU 12377.1.9** header, wrappers and dispatcher expose snapshot create, list, delete, rename, mount and revert operations. **`fs_snapshot_list` lists snapshots, not changed files.** No supported `fs_snapshot_diff` or equivalent changed-path iterator was identified. Mounting two snapshots and comparing them works in principle, but does not establish a sublinear diff. The manual records these APIs from macOS 10.13; the header has earlier availability annotations, so actual capability and authorization must be checked on deployment versions. [Snapshot API][snapshot-api], [header][snapshot-header], [wrappers][snapshot-wrappers].

Do not say “APFS cannot do deltas.” Apple demonstrated snapshot-delta replication in **macOS Catalina 10.15** at WWDC 2019. `asr --fromSnapshot ... --toSnapshot ...` uses a matching base snapshot at an APFS destination. Since Catalina, `asr` normally uses internal APFS replication. This is a volume replication/restore facility, not a documented changed-filename stream or a Go API that uploads a delta directly into restic. An intermediate APFS replica also conflicts with almost-zero spare disk. [Apple presentation][wwdc], [`asr` manual][asr].

The **2020-06-22 APFS format reference** documents object versions by transaction ID, snapshot extent-delta structures, dataless snapshots and a Time Machine backup-volume role. That proves such representations exist. It does **not** document an ordinary `fs_snapshot_create` option for a metadata-only snapshot, or a supported private Time Machine framework interface for third-party use. Reading APFS B-trees ourselves would be a filesystem/parser project, with live-access and encryption issues, not an available snapshot-diff call. [APFS reference, pp. 44–47, 66–69, 110, 117–121][apfs-format], [snapshot API][snapshot-api].

For what Time Machine actually uses, distinguish observations from contracts. A **Ventura 13.2.1** log-based investigation observed choices among FSEvents, initial/full listings, deep scans and snapshot deltas, with FSEvents preferred for subsequent backups. This is useful evidence against “Time Machine always uses APFS diff,” but not a current Apple API guarantee. No version-stable private-framework integration suitable for this daemon was established here. [Attributed investigation][time-machine-observation].

Snapshot creation/mounting also has authorization constraints. The inspected XNU dispatcher checks snapshot entitlements; root alone is not a general entitlement bypass. Listing follows a different bulk-attribute path. A pure-Go program can orchestrate Apple tools, but that is not a self-contained public Go snapshot API. Test signing, TCC, privileges and tool behavior on supported Macs rather than assuming an entitlement string found in source is freely provisionable. [Authorization source][snapshot-auth], [list wrapper][snapshot-wrappers], [`mount_apfs`][mount-apfs].

### FSEvents can reduce scans, but cannot promise none

Apple documents persistent per-device event streams. Directory events can be coalesced; opt-in file events have existed since **10.7**. The SDK says flags are hints and the stream must not be treated as a historical mutation log that can be replayed to reconstruct the filesystem. Apple explicitly calls history **advisory** and tells backup software to perform periodic full sweeps. The private `/.fseventsd` files are not a supported alternative API. [Programming guide][fsevents], [SDK header][fsevents-header], [security/private-log guidance][fsevents-security].

A conservative dirty-directory design must handle at least:

| Evidence or event | Safe interpretation |
| --- | --- |
| Normal directory notification | Compare that directory with the old manifest; discover additions and deletions from actual state. |
| `MustScanSubDirs` | Recursively reconcile the indicated subtree. |
| `KernelDropped` / `UserDropped` | Lost coverage: rescan monitored roots and descendants, not just the paths delivered. |
| `RootChanged`, remount, volume replacement | Revalidate root and volume identity; do not reuse a cursor against a different source. |
| Wrapped IDs, changed stream UUID, unavailable/purged/disabled history | Invalidate the fast path and rebaseline. IDs normally jump, so nonconsecutive IDs alone do not prove a gap. |
| New or moved-in directory | Discover its descendants unless their identity/content is independently known. |

The flags/identity contracts come from [Apple's guide][fsevents] and [SDK][fsevents-header]; the reconciliation policy is our proposed conservative response. There is no documented retention guarantee that a cursor survives arbitrary weeks of downtime, and a small dirty set is not a full inventory.

**Checkpoint trap:** if source snapshot `S` is taken at the start, an event received during its four-week upload may describe data absent from `S`. Saving the latest received event ID as the completed baseline would skip that change next time. Separate (a) notifications durably ingested, (b) the source snapshot boundary and (c) dirty work acknowledged by a committed repository snapshot. Persist dirty work before advancing ingestion; retain newer generations; clear work only after publication. This is a proposed protocol derived from the independent [snapshot][snapshot-api], [FSEvents][fsevents-header] and [restic commit][ordering] semantics.

Even a pre-snapshot cursor plus `FSEventStreamFlushSync` is **not a proof of lossless snapshot fencing**. The API promises delivery of already-occurred events, not an atomic snapshot/event-ID transaction. XNU also suppresses some repeated events in a short implementation window. Conservative overlap and tests help, but no finite overlap was proved sufficient. Periodic full scans can discover omissions later; they cannot retroactively make each earlier incremental complete. A strict complete-at-every-checkpoint contract therefore needs a stronger validated oracle or full reconciliation. [SDK flush/hint contracts][fsevents-header], [kernel event suppression][fsevents-source].

**Local-state trade:** keep a bounded set of dirty directories and recursive-invalidity markers, not a cache of all files. When it fills, promote entries to an ancestor or whole-volume-rescan marker. That can use little disk, but intentionally forfeits scan avoidance under overload. The prior restic trees supply the inventory. A single dirty directory containing a million entries still requires reconciling those entries. This is a design inference from [directory events][fsevents] and [restic's per-directory tree format][format-trees].

### Other APFS primitives worth distinguishing

| Primitive | Can it help? | Limit and stock-restic impact |
| --- | --- | --- |
| `getattrlistbulk` (**OS X 10.10+**) | Yes. Batch names and selected attributes for immediate directory entries, reducing syscall overhead. | Still enumerates entries, not a diff. In inspected XNU, some expensive requested attributes force a generic fallback. **v0.19.1** has no APFS-bulk-walk option; using this requires walker/engine work. [Manual][bulk], [fast path][bulk-source], [restic walk][walk]. |
| `searchfs` | Potentially useful volume catalog search, if the volume advertises support. | Not a reliable change list: deletions are absent, timestamps are not a transaction log, and no O(changes) guarantee is documented. Capability, attributes and behavior on APFS snapshots need testing; the API can require restarts if the catalog changes. [Manual][searchfs]. |
| `ATTR_CMN_GEN_COUNT` | A nonzero per-object data-generation count can support data reuse for the same object. | Not metadata/subtree equality; **zero is invalid and mmap'ed files return zero**. Still need discovery and identity. [Manual, lines 637–655][gencount]. |
| `ATTR_CMNEXT_RECURSIVE_GENCOUNT` | **A real documented lead:** a 64-bit APFS directory generation count updated when a child is modified. | Applies only to directories marked `maintain-dir-stats`; otherwise returns zero. No supported way to enable it on arbitrary existing roots, or complete metadata/hardlink coverage, was established here. Test before relying on it. Not used by stock **v0.19.1**. [Manual, lines 1338–1345][recursive-gen], [restic walk][walk]. |
| `clonefile` (**macOS 10.12+**) | Cheap initial copy-on-write file capture on the same filesystem. | Not a changed-file index. Directory cloning is documented as if each entry were cloned individually, not an O(1) subtree snapshot. Later writes consume space. [Manual][clonefile]. |

The recursive-generation field is a worthwhile new research question, **not grounds to claim there is categorically no possible APFS shortcut**. Support and semantics on the owner's arbitrary roots remain unverified. The inspected SDK mirrors contain it in 11.3 but not 10.15; that does not establish its exact first usable OS release. [10.15 header][attrs-old], [11.3 header][attrs-new], [current source manual][recursive-gen].

### A long-lived snapshot is not almost-free storage

An ordinary APFS snapshot pins data blocks as well as metadata. Its initial creation is cheap; later overwrites and deletions retain blocks required by that old state. It is volume-wide, so even an excluded high-churn directory can consume retained space. A four-week-held source snapshot can therefore retain a large fraction of the old volume. There is no fixed bytes-per-snapshot budget. [Snapshot manual][snapshot-api], [extent/snapshot format][apfs-format].

A manifest plus journal need not retain the previous source snapshot forever just to compare names. But a stable source used for an ongoing capture must remain available for that capture. Short-lived per-unit snapshots reduce exposure while making the overall backup a rolling capture, not one global instant. A snapshot also cannot make unsaved application memory consistent. These are design consequences of [snapshot scope and lifetime][snapshot-api].

## Raw blocks: not a simple internal-Mac escape hatch

### Plaintext or ciphertext depends on the interface

The most useful answer is **neither, for the proposed ordinary volume-node read**. Apple's `diskutil` manual says third-party code cannot open an APFS volume device node to directly access its on-disk bytes. `asr` says these nodes do not allow I/O from a standard process. An unlocked APFS volume is not an old CoreStorage-style exported plaintext block device. [Apple-authored manuals][diskutil], [ASR][asr].

| Interface | Defensible claim |
| --- | --- |
| Authorized file reads from a mounted, unlocked volume or snapshot | APFS supplies readable file contents, with permissions/privacy checks still applying. This is the normal restic source path. |
| Synthesized APFS volume, such as `/dev/rdiskCsV` | Ordinary direct third-party I/O is not supported. Do not promise a plaintext or ciphertext stream. |
| Synthesized container reference, such as `/dev/diskC` | An identification handle; Apple says it has no storage. The actual physical store(s) are different devices. |
| Original internal user-data media on Apple Silicon/T2 | Encrypted at rest, even with FileVault off; keys are hardware-bound. |
| Successful raw read from an actual internal physical-store device | **Not established here whether particular regions arrive plaintext or ciphertext.** Hardware at-rest encryption alone does not specify which transforms the driver endpoint applies. Requires hardware/OS/path-specific testing. |

Sources: [disk topology/access definitions][diskutil], [FileVault/Secure Enclave behavior][filevault], [Secure Enclave architecture][secure-enclave]. The **2020 APFS reference explicitly describes software encryption, not the full internal hardware-encryption implementation**. `/dev/r...` means the raw character-device interface, not “decrypted.” [Format, encryption chapter][apfs-format], [Apple raw-read dispatch source][raw-io].

If acquired bytes are original hardware-bound ciphertext, a disk image plus login password must **not** be advertised as recoverable after Mac loss or cryptographic erase. Apple documents UID-bound keys that are not exposed to the CPU and can be securely destroyed. This would contradict the map's recovery-with-only-S3-credentials-and-repo-password goal. This warning is conditional on the representation, not a claim that every logical replica produced by Apple tools is hardware-bound. [FileVault][filevault], [Secure Enclave][secure-enclave]. Apple also explicitly says Disk Utility cannot image individual APFS volumes, or APFS containers on Apple Silicon/T2 Macs. [Disk Utility guide][disk-images].

### Consistency, incremental cost and restores

A volume snapshot is not a frozen flat container image. APFS volumes share allocation within a container, and checkpoints/object maps have their own historical relationships. Taking a Data-volume snapshot and then reading the live physical store sequentially does not establish that all captured container/other-volume state belongs to one instant. A correct block approach needs stable offline capture, a snapshot-aware parser/exporter, or a tested Apple replication workflow. [APFS format][apfs-format], [snapshot definition][snapshot-api], [ASR replication][asr].

With **v0.19.1**, streaming a validated image through `--stdin` can store it as an ordinary backup file; stock restic restores **the image bytes**, not the individual Mac files inside. Without a reliable changed-block feed, each incremental still reads/hashes the whole image/store to discover reusable chunks. Raw blocks trade O(file count) metadata calls for potentially O(volume capacity) reads, including free/stale regions. Allocation maps are not changed-block maps. [Restic stdin docs][stdin], [chunk loop][file-read], [APFS allocation format][apfs-format].

Unchanged ciphertext can still deduplicate byte-for-byte, but identical plaintext at different encrypted locations need not match, and protected ciphertext is generally incompressible. Plain APFS blocks still have metadata/COW churn and chunk amplification. Single-file restore requires macOS to mount a valid portable image, or a separate APFS parser that understands checkpoints, object maps, extents, xattrs, compression and applicable keys. A pure-Go chunk store does not remove that work. [APFS format][apfs-format], [restic source-byte dedup][dedup].

**Verdict:** raw backup is not a justified default for this map. It does not provide a verified supported capture path, cheap incremental discovery, portable recovery and simple server-side file browsing together. Keep `asr` replication as documented prior art, not as an assumed public APFS-to-restic streaming API. [ASR][asr], [access restrictions][diskutil].

## Sparsebundles: a real, but deliberately opaque, workaround

### File-count and RAM benefit

An APFS sparsebundle is a directory-backed virtual disk. The outer directory contains numbered band files and control metadata. Apple's `hdiutil` manual documents **8 MiB default bands**, configurable in 512-byte sectors with `-imagekey sparse-band-size=16384` for 8 MiB. Inspect the actual bundle; creation-tool/version/large-image defaults should not be inferred from Time Machine examples. `-fs APFS` is supported. [Apple-authored `hdiutil` manual, SDK mirror][hdiutil].

Calculated, **not measured**:

| Model | Outer band positions or equivalent |
| --- | ---: |
| Five million 4 KiB file payloads, no filesystem overhead | 19.07 GiB, equivalent to 2,442 full 8 MiB bands |
| 20 GiB virtual image capacity | 2,560 band positions |
| 100 GiB virtual image capacity | 12,800 band positions |

Unwritten positions need not have files. APFS metadata, fragmentation, snapshots, partial bands and control files add qualifications; a 20 GiB image is **not assured to fit** those five million files. These are roughly 391–1,953 times fewer outer file entries, **not measured speedups**. **v0.19.1** now sees large band files and comparatively few tree nodes. This can turn millions of unique tiny blobs into tens of thousands of larger chunks, reducing index overhead, while inner filesystem metadata remains part of the image data. [Image layout][hdiutil], [restic per-file chunking][dedup], [index cost][index].

### Read and upload amplification

In **v0.19.1**, an unchanged band can reuse its content IDs. A changed band is reread to EOF and chunked; restic does not consult APFS dirty ranges. One 4 KiB edit can therefore trigger an 8 MiB band read. Only new chunks upload, so it does **not** imply an 8 MiB upload, but the upload can still exceed 4 KiB. Bigger bands increase this reread unit. COW allocation, inner metadata, installs/deletes and background indexing can dirty more bands than the application payload alone. [Change checks][walk], [read loop][file-read], [chunk sizes][dedup], [APFS COW behavior][apfs-faq].

Packing files changes dedup opportunities: identical tiny files at different image locations may lie in different surrounding chunks instead of sharing one small restic file blob. Conversely, repeated unchanged image chunks still deduplicate. **FileVault on the host is transparent to ordinary reads of an unencrypted image file. Encrypting the image itself or its inner APFS volume is different:** restic then sees protected regions as ciphertext, which hurts compression and cross-location dedup. It does not necessarily destroy incremental reuse of unchanged ciphertext. An encrypted image also adds its own recovery secret. [Image encryption][hdiutil], [FileVault][filevault], [restic chunk format][dedup].

### Do not copy live bands and assume they form one disk

The safe simple source is the **whole bundle after a clean detach**, not only `bands/`. Copying live bands can combine different times into one disk image. An **inner** APFS snapshot freezes its logical file view, not every backing band of the still-running container. Reading files from that inner snapshot works, but restores the many-file traversal. [Image attach/detach semantics][hdiutil], [APFS snapshot scope][snapshot-api], [restic read loop][file-read].

A plausible short-interruption workflow is: stop writers, cleanly detach the image, take a snapshot of the **outer APFS volume containing the bundle**, reattach the live image, then back up the detached-state bundle through the outer snapshot. This is a proposed composition of documented operations, not tested here. It preserves a stable image without keeping work stopped for the upload, but the outer snapshot pins old blocks while development resumes. Thus a four-week upload still conflicts with almost-full-disk operation. A flush plus a live sequential copy is not equivalent. [Snapshot retention][snapshot-api], [image lifecycle][hdiutil].

A **restic 0.17.3** forum discussion about Time Machine-to-NAS-to-B2 backups warns about live bundle consistency and suggests source snapshots. That report supports caution, not a claim that every live image copy fails or that our proposed workflow is validated. [Forum thread][bundle-report].

### Daily workflow and restoration costs

- **Mount lifecycle becomes part of development.** Use a stable mountpoint and refuse to build there if the image is absent; otherwise tools may create files in the underlying directory. Cargo supports `CARGO_TARGET_DIR`. Node layouts need validation: `npm ci` removes an existing `node_modules`, so a symlink arrangement is not universally safe. Source and lockfiles should remain independently file-backed-up. [Cargo docs][cargo], [npm docs][npm], [mountpoint options][hdiutil].
- **An idle read/write mount need not be byte-static.** Spotlight and other writers can change metadata. For artifact-only volumes, `mdutil -i off` controls indexing on the mounted inner volume; `hdiutil -nobrowse` only affects Finder visibility. Treat this as a configurable choice, not a universal requirement. [Manuals][mdutil], [hdiutil][hdiutil].
- **Deleted inner files do not necessarily shrink the host bundle immediately.** Inner snapshots retain blocks; `hdiutil compact` supports APFS/HFS+ sparse images, but is not restic prune. Old repository snapshots retain old band chunks until retention and prune remove their references. Avoid concurrent compact and backup of the same live bundle. [Compaction manual][hdiutil], [APFS snapshots][snapshot-api], [v0.19.1 retention docs][forget].
- **Restore/browse is image-level.** Stock **v0.19.1** can restore the complete bundle to a fresh directory. On a compatible Mac, attach it read-only and validate the filesystem and representative files. Restic `ls/find/diff` shows bands, not inner filenames. A Go reader on a server would need an additional image/APFS layer to provide inner-file browsing. Repository `check` validates the stored artifact, not the filesystem consistency it had when captured. [Restore docs][restore], [image tools][hdiutil], [format invariants][ordering].

**Verdict:** worth an opt-in experiment for heavy, deliberately opaque trees, not an automatic transformation of the whole Mac. Excluding truly reproducible `target`/`node_modules` is simpler when acceptable. If warm caches must be retained, start by measuring 8 MiB bands, idle/build/reinstall churn, actual source reads, new packed bytes, retained outer-snapshot space and full image recovery. The count reduction is real; the net speed and disk savings remain workload-dependent. [Band mechanics][hdiutil], [v0.19.1 cost path][file-read].

## Option summary and compatibility

“Stock restore” below means **restic v0.19.1** can restore what was actually stored. Restoring an opaque image is not the same as directly restoring one inner Mac file.

| Option | Avoids full ordinary-file walks? | Stock restore | Main cost / change to the map |
| --- | --- | --- | --- |
| Public snapshot plus stock backup | No | Normal files | Stable source, but pinned blocks and snapshot lifecycle. [Snapshot API][snapshot-api], [walk][walk]. |
| FSEvents plus stock `--files-from` | Selected paths only | Only that partial snapshot | Does not meet the complete-snapshot requirement. [Experiment/source][snapshot-write], [open merge PR][merge-pr]. |
| Change-aware standard-format writer | Can skip proven-clean subtrees | Normal files | New engine/correctness work; FSEvents alone is advisory; full blob index remains if reused. [Format][format-trees], [FSEvents][fsevents], [index][index]. |
| Recursive generation count | Potentially, on eligible directories | Normal files if writer uses the result correctly | Support, marking and complete mutation coverage unproved; new prototype question. [Apple contract][recursive-gen]. |
| Bulk attributes / catalog search | Cheaper enumeration, not a general complete diff | Normal files | Walker work; no format change; uncertain speedup. [Bulk][bulk], [search][searchfs]. |
| Raw APFS image | Trades file walks for block reads | Image bytes, if a valid portable image was acquired | Unsupported/unverified internal capture path, restore/parser scope and hardware-key risk. [Apple access rules][diskutil], [FileVault][filevault]. |
| Sparsebundle | Yes, for the inner tree; still walks bands | Complete bundle, not direct inner-file browsing | Source-layout change, mount lifecycle, consistency, churn and image recovery. [Image format][hdiutil], [restic read loop][file-read]. |
| Exclude reproducible trees | Yes, by not backing them up | Remaining included files | Coverage decision, not an engine feature. Path exclusions happen before metadata reads in **v0.19.1**. [Source][walk]. |

## What five million files cost

### Count files, blobs, directory width and xattrs separately

For **v0.19.1**, these are different scales:

| Resource | What drives it | Five-million-file example |
| --- | --- | --- |
| Backup walk | Included directory entries and their metadata calls | Still five million file visits per full run, even if data is unchanged. |
| Data index RAM | Distinct blobs retained across the whole repository, not current paths | Five million distinct nonempty files below 512 KiB usually mean five million data blobs. Duplicate files share blobs; empty files need no content blob. |
| Tree metadata | Nodes, names, timestamps, content IDs, xattrs, changed directory versions | Metadata grows with file count even when all file contents deduplicate. |
| Temporary tree RAM | Directory width, tree byte size, concurrent work and decoding/verification copies | Five million files spread across small directories are not equivalent to five million entries in one directory. |
| Local cache | Cached snapshot/index files and metadata packs | Not the source data size, and not a fixed percentage. There is no cache-size budget flag. |

Sources for the table: [walk][walk], [per-file chunk loop][file-read], [chunk sizing][dedup], [index][index], [node schema][node], [tree loading][tree-load], [cache selection][cache], [open cache-limit issue #4325][cache-limit].

**Index estimate:** the **v0.19.1** source estimates about **62 bytes per indexed blob**, excluding some allocator/header overhead, with stated pack-occupancy assumptions. Five million blobs are about **296 MiB** of index structures. Add an illustrative 50,000 directory blobs and the estimate becomes **299 MiB**. Retained older versions, duplicate index entries, GC headroom, upload/chunker/compressor buffers and metadata work come on top. This is not an RSS cap and not a promise that a 512 MiB Mac process budget will work. [Source and assumptions][index]. The separate [RAM investigation](https://github.com/djosh34/restic/issues/4) measured about 68 B live heap per blob and roughly 100 B RSS per blob in its particular v0.19.1 test.

**Tree-size experiment:** I marshaled one representative **v0.19.1 `data.Node`** in a tiny Go program inside the `/tmp` clone: a 20-character filename, 4 KiB size, one content ID, three nanosecond timestamps, UID/GID, user/group, inode and link count. It produced **348 bytes of JSON**. Adding one **256-byte xattr** produced **760 bytes** because the value is base64-encoded and has JSON framing. The Go struct alone was **328 bytes on Linux/arm64**, excluding referenced allocations. These are observations of that artificial node, not measurements of the owner's Mac. [Schema and serializer][node].

At five million entries, the first model is about **1.63 GiB of plaintext tree JSON**, including one separator byte per entry but excluding directory nodes and framing. The xattr model is about **3.54 GiB**. **Do not call either number the cache size or resident memory:** v2 tree packs are compressed and encrypted in the cache, and ordinary backup does not retain every decoded node in the entire source tree at once. Compression, unique content IDs, directory grouping and retained changed-tree versions determine the real result. [Sources: pack compression][format-packs], [cache][cache], [per-directory processing][walk].

### macOS xattrs can dominate ordinary file metadata

In **v0.19.1**, xattrs are embedded in tree-node JSON, not independently chunked/deduplicated file data. [Issue #3643][xattr-issue], originally reported against **0.12.1**, remains open. A related **0.12.0 / macOS 11.2.3** user report found roughly 400–450 MB of additions each hour and very large `com.apple.data-container-personality` attributes. This is evidence of a real failure mode, not a benchmark for modern macOS or v0.19.1. Compression added in **0.14.0** helps stored size, but does not remove large decoded trees or independent tree-version costs. [Sources: node schema][node], [original report][xattr-report], [compression changelog][compression].

**Very wide directories are still a separate risk in v0.19.1.** [Issue #2446][wide-issue] remains open. Its original 2.8 GB figure was for **0.9.5**, so should not be quoted as current. The newer unmerged [PR #22082][wide-pr] reports **1,248 MB peak RSS for v0.19.1 with one million empty files in one directory**, under its stated `GOMAXPROCS=2 GOGC=20` conditions. Treat that as the contributor's benchmark, not our measurement. Its proposed fix spills trees to a temp file, trading RAM for disk. Neither the fix nor that trade is free for a nearly full Mac. [Current `saveDir` allocation][walk].

### Almost no persistent cache is possible; zero workspace is not

For **v0.19.1**, `--no-cache` bypasses the persistent cache. It does not change the index's RAM requirement or the source walk. A normal cached incremental loads and parses parent trees; without cache, those reads must come from the backend. A change-aware writer could avoid loading clean subtrees, but that is the additional engine work above. [Sources: cache flag][cache-flag], [cache backend][cache], [parent tree loading][tree-load], [walk][walk].

Temporary upload packs remain. The **v0.19.1** tuning docs give a minimum of `pack size × (backend connections + 1)`: at the documented 16 MiB pack default and five S3 connections, about **96 MiB**, with other in-flight state and overhead beyond this minimum. `GOMAXPROCS` and connection counts reduce some buffers, not the whole-repository index. No APFS option changes these restic data structures. [Tuning docs][tuning], [index][index].

## Judging the user's experience

| Complaint or expectation | Verdict at restic v0.19.1 |
| --- | --- |
| “S3, deduplication and client-side encryption were good.” | Keep them. They remain **v0.19.1** capabilities. Standard-format subtree reuse preserves these repository properties; image aggregation changes the bytes available for dedup, not restic's encryption model. [Introduction][introduction], [format][format-all]. |
| “Millions of small files take forever, even if little changed.” | A real scaling limitation, not generally misuse. The full walk remains. One can avoid the extra progress scan, select a correct parent and exclude disposable trees, but cannot request complete snapshot merging from a delta list. [Walk][walk], [tuning][tuning], [open PR][changed-pr]. |
| “RAM and cache filled the Mac.” | Credible, still not bounded by default. Cache writes can fail the run; no-cache does not cap RAM or eliminate temp packs. Older timings and RAM figures need version qualification. [Cache error propagation][cache], [index][index], [tuning][tuning]. |
| “It never finished through sleep and interruptions.” | Partly improved, not solved by an APFS trick. Standby lock refresh was fixed in **0.16.0** and stuck HTTP requests gained forced interruption in **0.17.0**. **v0.19.1** still publishes the snapshot only after the run, so a change journal cannot invent the missing initial baseline. [CHANGELOG][changelog], [snapshot publication][snapshot-write], [ticket #2](https://github.com/djosh34/restic/issues/2). |
| “Another computer cannot view it because of locking.” | Not a file-count/APFS limitation. A running **v0.19.1** backup uses an append/shared lock. An unfinished first run has no published snapshot to browse. Exclusive maintenance and stale locks are distinct problems. [Backup lock][backup-open], [publication][snapshot-write], [ticket #3](https://github.com/djosh34/restic/issues/3). |
| “Cron, wrappers and no Keychain were painful.” | APFS does not solve this. **v0.19.1** documents external scheduling and external secret-store integration rather than providing a Mac service. The root launchd supervisor and Keychain work remain justified, independently of the engine decision. [Scheduling docs][scheduling], [secret-store FAQ][keychain], [ticket #5](https://github.com/djosh34/restic/issues/5). |
| “Back up changing files over four weeks.” | A live **v0.19.1** backup is not a single filesystem point in time, and its file-read loop does not verify a final stat against the initial stat. Short stable capture windows and rolling coverage are different guarantees from one four-week-held snapshot. Do not promise both consistency and no pinned-block cost. [Read loop][file-read], Apple snapshot discussion above. |

User reports support the problem, but not a universal throughput claim. In **0.9.4**, a Mac/High Sierra user reported a 33-million-file, 23 TiB initial backup taking over a month and subsequent runs taking 16 hours. The source was ZFS, not APFS. In **2024, version unstated**, [issue #4828][many-issue] reported multi-million-file runs taking 2–3 hours; a maintainer said Linux+SSD could check about a million files a minute, which is not a Mac guarantee. A **2021 HN user, version unstated**, reported successful 11-million-file, 8–15 TB backups and improved maintenance times. These show both pain and successful large deployments. [Mac report][old-mac-report], [HN comment][hn-report].

## Evidence limits and useful next experiments

This research ran on **Linux/arm64**, not a Mac. The only local experiments were the **v0.19.1** changed-target backup and node-serialization probes above. APFS throughput, physical-device reads, sparsebundle churn and mount behavior were not measured here. Apple API/source facts and compatibility concerns should not be mistaken for an end-to-end working prototype. Reddit search/fetch did not yield verifiable evidence for this specific APFS question; no Reddit anecdote is used to establish behavior.

Useful next experiments, if the owner chooses an option:

1. Inventory actual file count, largest directory, unique small-file content, xattr bytes, source bytes and free space. Compare two unchanged **v0.19.1** runs with/without progress scanning and cache. Measure scan time separately from index loading, payload reads and S3 transfer. [Relevant cost centers][walk], [index][index], [tuning][tuning].
2. For change tracking, inject journal gaps, daemon crashes and rename/delete storms, then compare a proposed complete snapshot with a stock full walk. Test journal checkpoint/source-snapshot boundaries explicitly. [Correctness risks][changed-pr], [format invariants][ordering].
3. For a sparsebundle, use a representative dev tree and count changed bands, bytes reread, new blobs, cache growth and restore time after a real build. Restore to a fresh Mac and mount read-only before declaring success. Do not accept “restic check passed” as proof that an inconsistently captured disk image is a valid APFS filesystem. [Restic checks repository reachability][ordering].

## Implications for the map

**Supervisor daemon.** Keep launchd, Keychain, sleep/wake supervision, disk-floor protection and explicit coverage status. With a stock **v0.19.1** engine, acknowledge full walks and use bounded backup units rather than promise delta-only complete snapshots. An FSEvents journal can avoid starting an unnecessary run or prioritize dirty units, but complete unchanged-subtree reuse needs a writer feature. Persist both the repository snapshot ID and journal boundary together. A lost journal must mean “rescan,” not “assume unchanged.” These are recommendations from the [stock walk][walk], [publication rules][ordering] and Apple evidence above.

**Read-only client.** Ordinary restic trees, including trees produced by a compatible change-aware writer, preserve stock restore and normal file browsing. Band files or a raw image preserve only the outer artifact in restic's namespace. Browsing inside that artifact adds an APFS/image reader and possibly another encryption secret. Do not silently turn the simple read-only restic client into a Mac disk-image service. [Restic tree format][format-trees].

**Low disk and low RAM.** Separate four budgets: persistent cache, upload temp space, in-memory blob index and blocks pinned by snapshots/clones. `--no-cache` addresses only the first. FSEvents plus subtree reuse addresses repeated source/metadata work, not the existing full index. Aggregating small files can shrink index/tree overhead, but trades away ordinary inner-file restore/browse and may amplify reads and changed chunks. A bounded dirty set is possible only with a fallback full-scan policy. [Index][index], [cache][cache], [tuning][tuning], Apple and image analysis above.

**Decisions and questions surfaced, not decided here:**

1. Does “no fork” mean a stock CLI only, or is a separately maintained, standard-format snapshot writer acceptable? The latter can reuse subtrees when change discovery is trustworthy, but is a larger responsibility than supervision. [Library boundary][library], [changed-files PR][changed-pr].
2. Are heavy disposable dev trees excluded, backed up as normal files, or deliberately moved into an image with an explicit opaque-restore contract? This changes user workflow and reader scope, not just a tuning value.
3. Is a complete snapshot allowed to be a rolling capture assembled over time, or must it reflect one stable source instant? A four-week retention window for the source snapshot conflicts with the almost-full-disk goal; short phases do not produce one global point-in-time Mac image.
4. Is advisory incremental discovery with periodic full audits acceptable, or must every checkpoint have independently established complete change coverage? FSEvents alone does not prove the latter. Investigate nonzero `ATTR_CMNEXT_RECURSIVE_GENCOUNT` on actual roots, including whether it can be enabled through a supported interface and covers all required mutation types. [FSEvents warning][fsevents], [recursive counter][recursive-gen].
5. If delta capture is chosen, require a Mac prototype testing journal/source-boundary correctness and stock-restic differential restore before putting it into the implementation plan. Passing tests do not strengthen Apple's API guarantee. If images are chosen, require restored-image mount tests and real-build churn measurements first.

The answer to “is there truly no way?” is **no, there are ways**. The practical choices are reduced scope, a different source representation, or a change-aware compatible writer. What **v0.19.1** does not offer is all of full ordinary-file snapshots, no repeated walk, almost no local state, and a stock-CLI-only supervisor at once. [Walk][walk], [open changed-file feature][changed-pr], [standard format][format-trees].

[release]: https://github.com/restic/restic/releases/tag/v0.19.1
[walk]: https://github.com/restic/restic/blob/v0.19.1/internal/archiver/archiver.go#L308-L663
[tuning]: https://github.com/restic/restic/blob/v0.19.1/doc/047_tuning_parameters.rst#L23-L123
[snapshot-write]: https://github.com/restic/restic/blob/v0.19.1/internal/archiver/archiver.go#L881-L989
[files-from]: https://github.com/restic/restic/blob/v0.19.1/doc/040_backup.rst#L533-L594
[rewrite]: https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_rewrite.go#L22-L53
[changed-pr]: https://github.com/restic/restic/pull/4469
[merge-pr]: https://github.com/restic/restic/pull/3405
[watch-issue]: https://github.com/restic/restic/issues/1502
[format-trees]: https://github.com/restic/restic/blob/v0.19.1/doc/design.rst#L390-L596
[format-packs]: https://github.com/restic/restic/blob/v0.19.1/doc/design.rst#L141-L240
[format-all]: https://github.com/restic/restic/blob/v0.19.1/doc/design.rst
[ordering]: https://github.com/restic/restic/blob/v0.19.1/doc/design.rst#L644-L691
[tree-load]: https://github.com/restic/restic/blob/v0.19.1/internal/data/tree.go#L148-L154
[backup-open]: https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L534-L574
[index]: https://github.com/restic/restic/blob/v0.19.1/internal/repository/index/index.go#L24-L49
[library]: https://github.com/restic/restic/issues/4406
[file-read]: https://github.com/restic/restic/blob/v0.19.1/internal/archiver/file_saver.go#L151-L247
[dedup]: https://github.com/restic/restic/blob/v0.19.1/doc/design.rst#L694-L712
[node]: https://github.com/restic/restic/blob/v0.19.1/internal/data/node.go#L21-L191
[cache]: https://github.com/restic/restic/blob/v0.19.1/internal/backend/cache/backend.go#L50-L195
[cache-flag]: https://github.com/restic/restic/blob/v0.19.1/internal/global/global.go#L98-L109
[cache-limit]: https://github.com/restic/restic/issues/4325
[xattr-issue]: https://github.com/restic/restic/issues/3643
[xattr-report]: https://forum.restic.net/t/tracking-down-large-metadata-changes/3850
[compression]: https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md#L3773-L3798
[wide-issue]: https://github.com/restic/restic/issues/2446
[wide-pr]: https://github.com/restic/restic/pull/22082
[changelog]: https://github.com/restic/restic/blob/v0.19.1/CHANGELOG.md
[scheduling]: https://github.com/restic/restic/blob/v0.19.1/doc/040_backup.rst#L750-L769
[keychain]: https://github.com/restic/restic/blob/v0.19.1/doc/faq.rst#L123-L150
[many-issue]: https://github.com/restic/restic/issues/4828
[old-mac-report]: https://forum.restic.net/t/low-performance-after-first-backup-and-restic-seems-to-spend-a-lot-of-time-doing-nothing/1727
[hn-report]: https://news.ycombinator.com/item?id=29216007
[snapshot-api]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/fs_snapshot_create.2
[snapshot-header]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/snapshot.h
[snapshot-wrappers]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/libsyscall/wrappers/fs_snapshot.c
[snapshot-auth]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_syscalls.c#L15214-L15324
[wwdc]: https://developer.apple.com/videos/play/wwdc2019/710/
[asr]: https://keith.github.io/xcode-man-pages/asr.8.html
[apfs-format]: https://developer.apple.com/support/downloads/Apple-File-System-Reference.pdf
[time-machine-observation]: https://eclecticlight.co/2023/03/01/how-does-time-machine-make-a-backup/
[mount-apfs]: https://keith.github.io/xcode-man-pages/mount_apfs.8.html
[fsevents]: https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html
[fsevents-header]: https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX11.3.sdk/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Headers/FSEvents.h
[fsevents-security]: https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/FileSystemEventSecurity/FileSystemEventSecurity.html
[fsevents-source]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_fsevents.c#L427-L534
[bulk]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/getattrlistbulk.2
[bulk-source]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_attrlist.c#L4353-L4414
[searchfs]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/searchfs.2
[gencount]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/getattrlist.2#L637-L655
[recursive-gen]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/getattrlist.2#L1338-L1345
[clonefile]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/clonefile.2
[attrs-old]: https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.15.sdk/usr/include/sys/attr.h
[attrs-new]: https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX11.3.sdk/usr/include/sys/attr.h
[hdiutil]: https://github.com/keith/xcode-man-pages/blob/f9e8d7ca45db0a3984314c4dd35fc12685b708af/docs/hdiutil.1.html
[diskutil]: https://keith.github.io/xcode-man-pages/diskutil.8.html
[filevault]: https://support.apple.com/guide/security/volume-encryption-with-filevault-sec4c6dc1b6e/web
[secure-enclave]: https://support.apple.com/guide/security/the-secure-enclave-sec59b0b31ff/web
[raw-io]: https://github.com/apple-oss-distributions/IOStorageFamily/blob/7edb88fbae296fb7c8ce2f64e115e116e566d51c/IOMediaBSDClient.cpp#L1218-L1238
[disk-images]: https://support.apple.com/guide/disk-utility/create-a-disk-image-dskutl11888/mac
[stdin]: https://github.com/restic/restic/blob/v0.19.1/doc/040_backup.rst#L672-L747
[apfs-faq]: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/FAQ/FAQ.html
[bundle-report]: https://forum.restic.net/t/timemachine-to-nas-to-b2/8766
[cargo]: https://doc.rust-lang.org/cargo/reference/config.html#buildtarget-dir
[npm]: https://docs.npmjs.com/cli/v11/commands/npm-ci
[mdutil]: https://keith.github.io/xcode-man-pages/mdutil.1.html
[forget]: https://github.com/restic/restic/blob/v0.19.1/doc/060_forget.rst
[restore]: https://github.com/restic/restic/blob/v0.19.1/doc/050_restore.rst
[introduction]: https://github.com/restic/restic/blob/v0.19.1/doc/010_introduction.rst
