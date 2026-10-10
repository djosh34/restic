# Research: what can GitHub-hosted macOS runners test for us?

Ticket: [#9](https://github.com/djosh34/restic/issues/9), part of map [#1](https://github.com/djosh34/restic/issues/1). Checked on 2026-10-10.

## TL;DR

- The standard arm64 runner is a fresh macOS VM (Veertu Anka, M1, 3 vCPU, 7 GB RAM, 14 GB SSD) with passwordless `sudo`. It is free and unlimited for this public repo. A job can run for at most 6 hours, and an account can run at most 5 macOS jobs at once. Nested virtualisation is not supported.
- **SIP is disabled** on the current `macos-15` and `macos-26` arm64 images (seen in live job logs from 2026-10-09). That makes most of our macOS checks possible.
- **Works on runners:** installing and loading a root LaunchDaemon with `sudo launchctl bootstrap system`. Creating and reading Keychain items in a custom keychain with no prompt. Writing generic passwords to `System.keychain` as root. Reading and writing the system TCC.db.
- **Very likely works, but still needs a probe:** granting Full Disk Access to our test binary by inserting a row into the system TCC.db; reading TCC-protected paths; `tmutil localsnapshot` plus `mount_apfs -s`. Job steps already have Full Disk Access, because the image grants it to `/bin/bash` and the runner's start script. So a daemon started by launchd is the only honest way to test the "no Full Disk Access" case.
- **Can't be tested on runners:**
  - Real sleep and wake. The image turns sleep off, and `pmset sleepnow` would likely kill the job.
  - IOKit power notifications.
  - Real dataless (`SF_DATALESS`) files. The flag can't be set with `chflags`. It needs a File Provider or iCloud.
  - Anything that needs a UI prompt or the System Settings Full Disk Access toggle.
  - Long runs (6 hours per job) and large data (14 GB disk).
- **Cheapest stand-ins:**
  - Sleep and wake: SIGSTOP/SIGCONT on restic, a fault-injecting proxy in front of S3, a wall-clock jump with `sudo date`, and a fake clock in Go. Most of this runs on Linux.
  - Dataless files: a faked `stat` flag, as restic's own test does.
  - Real sleep: a scripted `pmset relative wake` plus `pmset sleepnow` loop on the owner's own Mac.

## How this was checked

- The image build scripts in [actions/runner-images at 8197087](https://github.com/actions/runner-images/tree/8197087fc536320d1441203fdb5da9ae1b44b863/images/macos) (2026-10-09). The current `macos-26` arm64 image is 20260907.0351.1 (macOS 26.6.2) ([readme](https://github.com/actions/runner-images/blob/8197087fc536320d1441203fdb5da9ae1b44b863/images/macos/macos-26-arm64-Readme.md)).
- The GitHub docs and changelog.
- Public job logs from other projects that do the same things on hosted runners. I re-read the key logs myself (SIP status and TCC.db rows).
- restic v0.19.1 (the latest release, 2026-07-05), cloned to `/tmp/restic`.
- Go 1.26.3 runtime source.
- Nothing was run on a macOS runner for this ticket. The "probe" items below are the first thing a prototype ticket should run.

## 1. Runner facts and limits

| Fact | Value | Source |
|---|---|---|
| Labels for arm64 standard runners | `macos-14` (retiring), `macos-15`, `macos-26`, `macos-latest` (= macOS 26), `xcode-27` (preview, macOS 27) | [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [image migration changelog](https://github.blog/changelog/2026-05-14-github-actions-upcoming-image-migrations/), [Xcode 27 image](https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/) |
| macOS 14 retirement | 2026-11-02, with brownouts in October | [changelog](https://github.blog/changelog/2026-10-01-github-actions-macos-14-runner-image-retirement/), [runner-images#13518](https://github.com/actions/runner-images/issues/13518) |
| Standard arm64 hardware | 3 vCPU (M1), 7 GB RAM, 14 GB SSD | [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) |
| Larger arm64 (`-xlarge`) | 5 vCPU (M2), 14 GB RAM, 14 GB SSD; always billed, even on public repos; needs a Team or Enterprise plan | [larger runners](https://docs.github.com/en/actions/reference/runners/larger-runners), [billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions), [pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing) |
| Cost for this repo | Free: "Use of the standard GitHub-hosted runners is free and unlimited on public repositories." This repo is public. | [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) |
| Cost if the repo went private | $0.062 per minute for standard macOS, after the plan's included minutes (prices cut on 2026-01-01) | [pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing), [changelog](https://github.blog/changelog/2026-01-01-reduced-pricing-for-github-hosted-runners-usage/) |
| Time per job | 6 hours, then "the job is terminated and fails" | [limits](https://docs.github.com/en/actions/reference/limits) |
| Time per workflow run | 35 days, including waiting | [limits](https://docs.github.com/en/actions/reference/limits) |
| Concurrent macOS jobs | 5 on Free and Pro, shared across the whole account | [limits](https://docs.github.com/en/actions/reference/limits) |
| Nested virtualisation | "Nested-virtualization is not supported due to the limitation of Apple's Virtualization Framework." It is still unavailable on macOS 15 and 26 as of January 2026. | [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [runner-images#13505](https://github.com/actions/runner-images/issues/13505#issuecomment-3724643248), [#9460](https://github.com/actions/runner-images/issues/9460) |
| Admin rights | "The Linux and macOS virtual machines both run using passwordless `sudo`." | [GitHub-hosted runners, Administrative privileges](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#administrative-privileges) |

So we can't run a Tart or UTM VM inside a runner to test sleep, reboots or a clean install. Each job is a fresh VM, so state can't carry from one job to the next except through artifacts or the S3 bucket.

## 2. What the image already changes on the VM

These settings decide what our tests can and can't see.

- **The VM is built with Veertu Anka** ([template L87-L92](https://github.com/actions/runner-images/blob/8197087fc536320d1441203fdb5da9ae1b44b863/images/macos/templates/macOS-26.arm64.anka.pkr.hcl#L87-L92)).
- **SIP is off.**
  - The build script says "Disable analytics daemon (requires SIP to be disabled)" and then unloads a `/System` daemon ([configure-system.sh L23-L24](https://github.com/actions/runner-images/blob/8197087fc536320d1441203fdb5da9ae1b44b863/images/macos/scripts/build/configure-system.sh#L23-L24)).
  - Live jobs on 2026-10-09 printed `System Integrity Protection status: disabled.` on [macos-15-arm64 20260907.0337.1](https://github.com/GPSBabel/gpsbabel/actions/runs/37973431895/job/113968347411#step:5:1) and [macos-26-arm64 20260907.0351.1](https://github.com/GPSBabel/gpsbabel/actions/runs/37973431895/job/113968347235#step:5:1).
- **Full Disk Access is pre-granted** in the system TCC.db to `/bin/bash`, `/opt/hca/start_hca.sh` and `/usr/local/opt/runner/runprovisioner.sh` ([configure-tccdb-macos.sh L40-L43](https://github.com/actions/runner-images/blob/8197087fc536320d1441203fdb5da9ae1b44b863/images/macos/scripts/build/configure-tccdb-macos.sh#L40-L43)). The rows are added with plain `sudo sqlite3 ... INSERT` ([utils.sh L161-L166](https://github.com/actions/runner-images/blob/8197087fc536320d1441203fdb5da9ae1b44b863/images/macos/scripts/helpers/utils.sh#L161-L166)). A live `macos-26` job could read the system TCC.db and saw these rows ([job log](https://github.com/T0mSIlver/localvoxtral/actions/runs/33314730362/job/99265930473#step:5:1)). That file is itself protected by Full Disk Access, so **job steps already run with Full Disk Access.**
- **Time Machine is disabled.** The image runs `sudo tmutil disable` and `launchctl unload -w .../com.apple.backupd.plist` ([configure-system.sh L29-L31](https://github.com/actions/runner-images/blob/8197087fc536320d1441203fdb5da9ae1b44b863/images/macos/scripts/build/configure-system.sh#L29-L31)).
- **Sleep is off.** The image sets `pmset -a hibernatemode 0` and `pmset -a sleep 0 disksleep 0 displaysleep 0` ([configure-machine.sh L12-L17](https://github.com/actions/runner-images/blob/8197087fc536320d1441203fdb5da9ae1b44b863/images/macos/scripts/build/configure-machine.sh#L12-L17)).
- **The runner user is logged in to the GUI automatically** ([configure-autologin.sh L9-L12](https://github.com/actions/runner-images/blob/8197087fc536320d1441203fdb5da9ae1b44b863/images/macos/scripts/build/configure-autologin.sh#L9-L12)), so `gui/501` launchd domains exist.
- **macOS 27 moves the user TCC.db** to `/private/var/containers/Data/ProtectedSystem/...`. The system TCC.db stays at `/Library/Application Support/com.apple.TCC/TCC.db` ([configure-tccdb-macos-27.sh L22-L25, L108](https://github.com/actions/runner-images/blob/8197087fc536320d1441203fdb5da9ae1b44b863/images/macos/scripts/build/configure-tccdb-macos-27.sh#L22-L25)). Tests that edit TCC.db will need small changes for each OS.

## 3. Item by item

| Item | Verdict | Evidence |
|---|---|---|
| Root LaunchDaemon via `sudo launchctl bootstrap system` | **Works** (`macos-15` and `macos-26` arm64) | A root-owned plist was bootstrapped in a [successful macos-15 job](https://github.com/PKXLIVE/openassetwatch/actions/runs/34816667343/job/103888688455) ([workflow L1181-L1183](https://github.com/PKXLIVE/openassetwatch/blob/9dd88f7dc1e09a33c173cf62e2d618e6542157cd/.github/workflows/agent-ci.yml#L1181-L1183)). The Nix installer logs "Bootstrap ... via `launchctl bootstrap system /Library/LaunchDaemons/...`" on macOS 26 arm64 ([job](https://github.com/DeterminateSystems/nix-installer/actions/runs/37402286644/job/112072446272#step:6:1)). |
| `gui/501` LaunchAgent | **Works** (macOS 14 arm64) | [all-smi job](https://github.com/lablup/all-smi/actions/runs/38056235558/job/114225994777#step:9:1), [workflow L945-L952](https://github.com/lablup/all-smi/blob/c3054e27de740416ea3a8cfade0ebfb8233d65e3/.github/workflows/ci.yml#L945-L952). Not needed for us, because the owner chose a root LaunchDaemon. |
| Custom keychain: create, unlock, add, read, no prompt | **Works** (macOS 26 arm64) | `security create-keychain`/`unlock-keychain`/`add-generic-password -A` and real reads in a [successful job](https://github.com/link-assistant/router/actions/runs/37704829784/job/113076582346) ([workflow L65-L109](https://github.com/link-assistant/router/blob/50170b6ae591f9d3518d242ad35a6248aed6b35a/.github/workflows/macos-keychain.yml#L65-L109)). `SecItemAdd`/`SecItemCopyMatching` from native code against a custom keychain also passes in hosted CI ([osx-keychain workflow L51-L71](https://github.com/alexleighton/osx-keychain/blob/c83c6f0a15975ec4d8077dadbf37b50d3b9eb9f4/.github/workflows/ci.yml#L51-L71), [run](https://github.com/alexleighton/osx-keychain/actions/runs/28963285344)). |
| `System.keychain` generic password as root | **Works** (macOS 26 arm64, larger runner) | The Nix installer runs `security add-generic-password ... -T ... /Library/Keychains/System.keychain` as root ([source L204-L237](https://github.com/DeterminateSystems/nix-installer/blob/3b69a695c946a51461439d306ae5522ff574c12f/src/action/macos/encrypt_apfs_volume.rs#L204-L237)) in a [successful job](https://github.com/DeterminateSystems/nix-installer/actions/runs/37402286644/job/112072446272#step:6:1). Not yet shown on a standard `macos-15` runner. |
| Keychain read by our daemon after the binary changes | **Probe** | `-T` names an app that "may access this item" ([security(1) L458-L464](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/SecurityTool/macOS/security.1#L458-L464)). File-based keychain ACLs identify apps by code signature ([TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)). An ad-hoc-signed rebuild may therefore lose access. In a daemon with no UI, that shows up as `errSecInteractionNotAllowed` ([Apple](https://developer.apple.com/documentation/security/errsecinteractionnotallowed)). The runner can show this for real: store with `-T v1`, swap in v2, and read from the LaunchDaemon. |
| Data-protection keychain (`kSecUseDataProtectionKeychain`) | **Not testable without signing** | It needs provisioning-backed entitlements ([TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)). Outside our design anyway: a root daemon uses the System keychain. |
| One `trust-settings` authorisation change | **Fails** (macOS 15) | `security authorizationdb write com.apple.trust-settings.admin allow` gives `NO (-60005)` ([runner-images#11893](https://github.com/actions/runner-images/issues/11893)). Not needed for us. |
| Grant Full Disk Access to a test binary | **Probe, likely works** | SIP is off and the system TCC.db can be written with `sudo sqlite3`, which is how the image grants it to bash (section 2). Other projects insert system TCC rows for other services ([Sunshine L73-L94](https://github.com/LizardByte/Sunshine/blob/cd370564d532e1c60729adeca59cb3a783abe717/.github/workflows/ci-homebrew.yml#L73-L94), [AWS Nuke tests L90-L97](https://github.com/aws-deadline/deadline-cloud-for-nuke/blob/02eeda39ddc8f7d476c6e2472b9c605ab64650cc/.github/workflows/integ_macos.yml#L90-L97), which also restarts `tccd`). Apple says the TCC.db format is an implementation detail and edits may not take effect ([Apple forum 740055](https://developer.apple.com/forums/thread/740055)). User-TCC inserts were flaky on some images ([runner-images#14566](https://github.com/actions/runner-images/issues/14566), [#12616](https://github.com/actions/runner-images/issues/12616#issuecomment-3620055076)). No one has shown an inserted Full Disk Access row taking effect for an arbitrary binary. |
| "No Full Disk Access" case | **Probe, likely works** | Job steps inherit Full Disk Access (section 2), so a plain test step can't see a denial. A LaunchDaemon started by launchd is its own responsible process, so it should be denied until granted. |
| Read TCC-protected paths (`~/Library/Mail`, `~/Library/Safari`, Messages) | **Probe** | No hosted-runner test found. The folders may not exist on a fresh VM, and a missing folder gives `ENOENT`, not a TCC denial. The test should create content as the job step (which has Full Disk Access) and then read it from the daemon with and without the grant. |
| `tmutil localsnapshot`, `listlocalsnapshots`, `mount_apfs -s` | **Probe** | No hosted-runner run found ([sub-agent search](#sources-for-sub-agent-searches)). `localsnapshot` makes "local Time Machine snapshots of all APFS volumes included in the Time Machine backup" ([tmutil(8)](https://keith.github.io/xcode-man-pages/tmutil.8.html)). The image has disabled Time Machine and `backupd` (section 2), so the probe may need `sudo tmutil enable` or `launchctl load -w` of `backupd` first. SIP being off allows that. Mounting needs root and Full Disk Access ([forum](https://forum.restic.net/t/utilizing-macos-local-apfs-snapshots-for-restic-backups/4232), [mount_apfs(8)](https://keith.github.io/xcode-man-pages/mount_apfs.8.html)). Job steps have both. The direct `fs_snapshot_create` API needs an Apple-granted entitlement ([xnu man page L73-L87](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/fs_snapshot_create.2#L73-L87)), so `tmutil` is the only route for us anyway. |
| `SF_DATALESS` files | **Not testable for real** | `SF_DATALESS` is `0x40000000`, inside `SF_SYNTHETIC` ("system read-only synthetic flags"), outside `SF_SETTABLE` ([xnu stat.h L496-L520](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/stat.h#L496-L520)). Setting it from user space is undefined ([chflags.2 L104-L110](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/chflags.2#L104-L110)). Real dataless files come from a File Provider (iCloud or a signed extension such as Apple's FruitBasket sample) ([TN3150](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files), [evictItem](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/evictitem(identifier:completionhandler:))). Runners are not signed in to iCloud. restic v0.19.1 itself only tests this with a faked `Stat_t.Flags` ([stat_darwin_test.go L60-L68](https://github.com/restic/restic/blob/v0.19.1/internal/fs/stat_darwin_test.go#L60-L68)); the real check is in [stat_darwin.go L40-L55](https://github.com/restic/restic/blob/v0.19.1/internal/fs/stat_darwin.go#L40-L55) behind `--exclude-cloud-files` (default off, [cmd_backup.go L153-L155](https://github.com/restic/restic/blob/v0.19.1/cmd/restic/cmd_backup.go#L153-L155)). |
| Real sleep and wake | **Not testable** | The image sets sleep to 0 (section 2). A self-hosted workflow warns "A `pmset sleepnow` from inside the job kills the runner that is running it" ([workflow L79-L81](https://github.com/ranajoy18/naukri-profile-refresh/blob/eb2c35cbdab0b02c3c80f5d2030073f1cd24ccea/.github/workflows/daily-refresh.yml#L79-L81)). No evidence of a hosted VM sleeping and waking inside a job. `caffeinate` runs, but proves nothing about sleep ([basecamp workflow L60-L64](https://github.com/basecamp/basecamp-cli/blob/40e4757702cf695cfec6b47b9d768177b3697014/.github/workflows/headless-probe-composition.yml#L60-L64)). |
| Power notifications (IOKit will-sleep / did-wake) | **Not testable** | They fire only on real sleep. |
| Clock behaviour after sleep | **Partly simulable** | Go 1.26.3 on darwin reads its monotonic clock from `mach_absolute_time` ([sys_darwin_arm64.s L145-L147](https://github.com/golang/go/blob/go1.26.3/src/runtime/sys_darwin_arm64.s#L145-L147)). That clock does not advance during sleep: xnu describes `mach_continuous_time` as "like mach_absolute_time, but advances during sleep" ([mach_time.h L62-L68](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/mach/mach_time.h#L62-L68)). Go's docs warn about the same thing ([time.go L54](https://github.com/golang/go/blob/go1.26.3/src/time/time.go#L54)). After a real sleep the wall clock jumps and Go timers don't count the sleep. `sudo date` on a runner reproduces the wall-clock jump without a monotonic jump. NTP may undo it, so turn network time off first. SIGSTOP does not reproduce this, because both clocks keep running. |

## 4. What can't be tested there, and the cheapest stand-in

| Can't test on a hosted runner | Cheapest stand-in | Runs on |
|---|---|---|
| Real sleep and wake | Scripted cycles on the owner's Mac: `sudo pmset relative wake 120; pmset sleepnow` in a loop with the daemon running. pmset documents both commands ([pmset(1)](https://keith.github.io/xcode-man-pages/pmset.1.html)). Don't use a self-hosted runner on this public repo for this, because fork PRs could run code on the owner's Mac. | Owner's Mac, by hand, before release |
| Process frozen during sleep | SIGSTOP/SIGCONT on the restic child. This is the pause method the map already favours. | Linux CI |
| Dead TCP connections and no network after wake | A small fault-injecting proxy (Go) between restic and the S3 stand-in that resets connections or drops traffic for N minutes | Linux CI |
| Wall clock jumps, monotonic clock doesn't | Injected clock in the daemon's Go code (unit tests). Plus one `sudo date` jump on a macOS runner as a smoke test. | Linux CI, plus one macOS job |
| IOKit power notifications | Don't depend on them. Detect wake by comparing wall time with monotonic time. This is pure Go and needs no cgo. If they are used, put them behind an interface and feed fake events. | Linux CI |
| Real dataless files | Fake the stat flag behind the same check restic uses. Test the materialise-off path (`setiopolicy_np`, `EDEADLK`; see [TN3150](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files)) only on the owner's Mac with iCloud Drive. | Linux and macOS CI, plus owner's Mac |
| System Settings Full Disk Access toggle and prompts | Insert the TCC row directly on the runner (probe). Check the real toggle once by hand on the owner's Mac. | macOS runner, plus owner's Mac |
| Multi-week, multi-TB first backup | A scaled-down repo with many forced interruptions inside a 6-hour job. Most of it runs on Linux, because resume logic doesn't depend on macOS. | Linux CI |
| Nearly full disk | A small disk image: `hdiutil create -size 2g -fs APFS` and attach it on macOS. A small loop or tmpfs mount on Linux. Don't fill the runner's root disk. | Both |
| Clean install, reboot, OS update | Not possible: no nested VMs and no reboot inside a job. Reboot behaviour (LaunchDaemon `RunAtLoad`) is checked by hand on the owner's Mac. | Owner's Mac |
| Real B2 | `rclone serve s3` or a local S3 server. restic v0.19.1's own macOS CI already installs a local MinIO and rclone ([tests.yml L29-L31, L67-L94](https://github.com/restic/restic/blob/v0.19.1/.github/workflows/tests.yml#L67-L94)). Add a small real-B2 job that uses repo secrets and runs only on pushes by the owner. | Linux CI |

## 5. A first probe job (for a prototype ticket)

One workflow, matrix `macos-15` and `macos-26`, about 10 minutes each, free. It should print a pass or fail line for each of these:

1. `csrutil status`, `sw_vers`, `df -h /`, the image version.
2. Build a tiny Go probe binary and ad-hoc sign it. Install it as `/Library/LaunchDaemons/x.plist` and `launchctl bootstrap system`. The daemon tries to read a file the job step put in `~/Library/Safari` and the system TCC.db, then writes the result to a log. Expected: denied.
3. Insert a `kTCCServiceSystemPolicyAllFiles` row for the probe path, restart `tccd`, kickstart the daemon. Expected: allowed.
4. `sudo security add-generic-password -T <probe> ... /Library/Keychains/System.keychain`. The daemon reads it. Rebuild the probe so its hash changes, replace it and read again. This records whether access survives an update.
5. Re-enable `backupd` if needed. Then `tmutil localsnapshot`, `tmutil listlocalsnapshots /System/Volumes/Data`, `mount_apfs -o nobrowse,ro -s <name> /System/Volumes/Data /tmp/snap`, read a file and unmount. Watch `df` before and after.
6. Turn network time off. `sudo date` +8h. Check that the probe daemon notices the gap between wall time and monotonic time.

## 6. User experience, judged against this ticket

- **"Kept failing across sleep/wake":** no hosted runner can reproduce this. It can only be tested on a real Mac, or by parts with the stand-ins in section 4. The earlier research ([#2](https://github.com/djosh34/restic/issues/2)) found the sleep-related lock bugs fixed in restic 0.16 and 0.17. What remains is resume and flush behaviour, and that can be tested on Linux.
- **"No Keychain integration" and "painful setup":** the parts that are ours (System keychain item, LaunchDaemon install, Full Disk Access check) can mostly be tested on runners. The one real risk is that access is lost when the binary changes, and runners can show that.
- **Files changing during the backup (APFS snapshots):** probably testable on runners. This needs a probe because the image turns Time Machine off.

## Implications for the map

**Supervisor daemon**

- Its macOS glue can run in CI for free: install, `launchctl bootstrap system`, System keychain, Full Disk Access present or missing, and probably snapshot create, mount and delete. The rest should be plain Go that runs on Linux.
- Detect sleep in pure Go by comparing the wall clock with Go's monotonic clock. Don't use IOKit power callbacks, which need cgo and can't be tested in CI. Timers must not assume the monotonic clock counts sleep.
- Put the clock and network behind interfaces so sleep and wake can be simulated on Linux.

**Read-only client**

- It runs on a Linux server, so it needs nothing from macOS runners. Test it on Linux against a repo the Mac side writes, including during a concurrent prune.

**Low-disk and low-RAM goals**

- The 14 GB runner disk and 7 GB RAM are too small for real-size tests. Use small APFS disk images for the free-disk floor, and synthetic large repos on Linux for RAM.
- Each local APFS snapshot pins space, so the snapshot probe should also measure `df` while one is mounted.

**Decisions this surfaces**

- **Signing.** An ad-hoc-signed build may lose both the Keychain ACL match and a csreq-bound Full Disk Access grant on every update. Runners can test this, but the fix is a design choice:
  - (a) a Developer ID signature with a stable designated requirement,
  - (b) a path-only TCC grant plus `-A` on a root-only System keychain item, or
  - (c) re-running `setup` after each update.
  This feeds the "packaging and updates" fog item.
- **Real-Mac test pass.** Is a scripted, by-hand pass on the owner's Mac (sleep/wake loop, real Full Disk Access toggle, iCloud dataless files) part of "done"? Runners cannot cover these.

**New questions**

- Does `tmutil localsnapshot` work in an Anka VM with Time Machine re-enabled and no destination? The probe answers this.
- Does an inserted TCC row take effect for a launchd-started binary without a reboot? The probe answers this.
- Which macOS versions do we support? `macos-14` is retired on 2026-11-02, and the `xcode-27` image already ships macOS 27, which moves the user TCC.db.

## Sources for sub-agent searches

Legwork used three `pi/openai-codex/gpt-6.1-sol` helpers via paseo: runner limits and billing; permissions evidence from public jobs; and dataless files and APFS. I re-checked the key claims myself:

- SIP status in the GPSBabel job logs.
- The TCC rows in the localvoxtral log.
- The GitHub docs quotes on hardware, nested virtualisation, `sudo` and limits.
- The restic v0.19.1 and xnu line references.

Searches for `tmutil localsnapshot` and `mount_apfs -s` in public workflows returned no hosted-runner runs. The only `tmutil` hits were cleanup commands such as `sudo tmutil deletelocalsnapshots / || true` ([PDFApps L135-L140](https://github.com/nelsonduarte/PDFApps/blob/5245e0b8a029c7dbdec427ce3ec8285a72aa1628/.github/workflows/build.yml#L135-L140)).
