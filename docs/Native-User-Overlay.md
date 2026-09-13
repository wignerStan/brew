# Native per-user overlay on Linux

This fork can use one administrator-managed Homebrew installation as a read-only
lower package layer while each developer writes to a second, ordinary Homebrew
prefix in their home directory. It does not run a daemon, create named
environments, assign packages to users, or introduce a separate package-store
layout.

The default paths use native Homebrew-on-Linux locations:

```text
/home/linuxbrew/.linuxbrew/        administrator prefix; read-only to developers
$HOME/.linuxbrew/                  developer prefix; owned by one developer
├── bin/
├── Caskroom/
├── Cellar/
├── etc/
├── Frameworks/
├── include/
├── lib/
├── opt/
├── sbin/
├── share/
└── var/
```

`XDG_DATA_HOME` does not affect package placement. Unless explicitly overridden
with `HOMEBREW_OVERLAY_USER_PREFIX`, the writable prefix is always
`$HOME/.linuxbrew`.

## Effective formula view

`$HOME/.linuxbrew/Cellar` is a real directory. When a formula has no private
realization, its user rack is a managed read-only symlink to the administrator
rack:

```text
$HOME/.linuxbrew/Cellar/cmake
    -> /home/linuxbrew/.linuxbrew/Cellar/cmake
```

When the developer installs another version, the user rack becomes a real
native Homebrew rack. Private versions are real directories and administrator
versions are exact read-only symlinks:

```text
$HOME/.linuxbrew/Cellar/cmake/
├── 4.0.0 -> /home/linuxbrew/.linuxbrew/Cellar/cmake/4.0.0
└── 4.2.0/                         private developer keg
```

A real user keg with the same version name intentionally shadows the
administrator realization. Any other existing object at an inherited version
path is a synchronization conflict; Homebrew does not silently accept or
replace it.

After the last private version is removed, the effective package becomes
administrator-provided again. The synchronizer may represent that state as a
rack symlink or as a real rack containing only exact inherited-version links;
both forms are classified as inherited and are read-only to formula commands.

The private rack owns the active user `opt` and linked-keg records while it has a
real local version. When no private version exists, those records fall back to
the administrator prefix.

Homebrew does **not** recursively project the administrator's general `bin`,
`lib`, `include`, `share`, `etc`, or `var` trees into the user prefix. Those
trees cannot be combined safely with ordinary symlinks. `brew shellenv` instead
places executable prefixes in this order:

```text
$HOME/.linuxbrew/bin
$HOME/.linuxbrew/sbin
/home/linuxbrew/.linuxbrew/bin
/home/linuxbrew/.linuxbrew/sbin
```

The inherited Cellar and `opt` records let Homebrew resolve lower formulae and
dependencies. The two general-purpose prefix trees are not presented as a
filesystem union. The administrator `bin`, `sbin`, and `Caskroom` trees are not
linked into the user prefix, and the download cache remains independent.

## Enable the overlay

The preferred per-user configuration is
`${HOMEBREW_USER_CONFIG_HOME}/overlay.env`, which defaults to
`$HOME/.homebrew/overlay.env`:

```text
HOMEBREW_OVERLAY=1
HOMEBREW_OVERLAY_BASE_PREFIX=/home/linuxbrew/.linuxbrew
```

The file is parsed as assignments, not sourced as shell code. It must be a
regular, non-symlink, user-owned file and must not be group- or world-writable.
`$HOME/.homebrew/brew.env` may contain the same overlay variables for backward
compatibility.

A site administrator may instead place the settings in
`/etc/homebrew/brew.env`. Overlay settings always use this precedence, including
when `HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY` is set for other Homebrew settings:

```text
invoking process > user overlay.env/user brew.env > system configuration
```

The administrator prefix must be readable and executable by developers but not
writable by them. One example is:

```sh
sudo chown -R admin:dev /home/linuxbrew/.linuxbrew
sudo chmod -R u+rwX,g+rX,g-w,o-rwx /home/linuxbrew/.linuxbrew
sudo find /home/linuxbrew/.linuxbrew -type d -exec chmod g+s {} +
```

Add developers to `dev` and start a new login session after changing group
membership.

A developer invokes the administrator launcher normally:

```sh
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

When the administrator prefix is not writable, the launcher initializes
`$HOME/.linuxbrew`, creates `$HOME/.linuxbrew/bin/brew` as a symlink to the
administrator-managed Homebrew repository, and re-executes through the user
prefix.

Generated runtime overlay settings are stored in:

```text
$HOME/.linuxbrew/etc/homebrew/overlay.env
```

This is a managed bootstrap file, not the developer configuration file.
Initialization does not replace the developer-owned user configuration or
`$HOME/.linuxbrew/etc/homebrew/brew.env`.

## Formula command behavior

| Operation | Behavior in the developer prefix |
| --- | --- |
| `brew install foo` when an inherited version satisfies the request | Reuses the administrator formula without copying it |
| `brew upgrade foo` or `brew reinstall foo` | Builds or pours a private realization; inherited first replacement uses atomic rack exchange, while an existing private keg uses an owner-locked crash-recovery backup |
| `brew uninstall foo` for a private version | Removes only the private keg; inherited fallback becomes effective when no private version remains |
| `brew uninstall --force foo` for a mixed rack | Removes all private versions and preserves every inherited version |
| `brew uninstall foo` for an inherited-only formula | Refuses to modify the administrator package |
| `brew cleanup` | Ignores inherited administrator kegs |
| `brew autoremove` | Evaluates and removes unnecessary private kegs even when another version is inherited |
| `brew bundle cleanup` | Excludes inherited-only formulae and uses private-only force removal |
| `brew link`, `brew unlink`, or `brew postinstall` on an inherited-only formula | Refuses the mutation; create a private realization first |
| `brew pin foo` on an inherited-only formula | Refuses because administrator-owned bytes can disappear; run `brew reinstall foo` first |
| `brew pin foo` on a mixed rack | Pins the newest user-owned realization, never a newer inherited keg |
| `brew overlay-sync` | Forces a locked structural reconciliation; suitable for a daily cron job |
| Migration into a name supplied by the base | Refuses before moving, merging, or deleting local files |

The overlay is formula-first. Administrator casks are not inherited because cask
artifacts can be installed outside the Homebrew prefix and have separate
uninstall semantics. A developer may still install a cask into their own prefix,
subject to the cask's normal destinations and privilege requirements.

## Mutation serialization and crash markers

Every patched native package mutation uses a per-prefix advisory lock:

```text
$HOME/.linuxbrew/var/homebrew/locks/overlay-mutation.lock
```

Before the first filesystem change, the lock owner writes:

```text
$HOME/.linuxbrew/var/homebrew/overlay-generation.dirty
```

The same protocol is used in the writable administrator prefix. A normal
completion publishes the new explicit generation and removes the dirty marker.
If a process is killed, its kernel lock is released but the dirty marker remains.
The next invocation must perform structural reconciliation before it can restore
the generation fast path.

A second invocation cannot inspect or bless a live transient package view. It
fails with an active-mutation error and must be retried after the first command
finishes. This intentionally favors consistency over concurrent commands in the
same user prefix.

## Formula transaction startup

Replacing an inherited formula has a transaction-specific owner lock for its
entire staging and publication lifetime:

```text
$HOME/.linuxbrew/var/homebrew/overlay/transactions/.locks/<id>.lock
```

Startup follows this order:

1. Acquire the transaction owner lock.
2. Acquire the global package-mutation lock and publish the dirty marker.
3. Verify the administrator generation and validate the inherited rack.
4. Write all required journal metadata under a private hidden directory:
   `transactions/.new-<id>`.
5. `fsync` the journal files and directory.
6. Publish the complete journal with one directory rename to
   `transactions/<id>`.
7. Create the private staging rack.

Recovery therefore sees either no visible journal or a complete visible journal.
A process killed while creating `.new-<id>` leaves hidden pending state that is
removed only after recovery can acquire its owner lock. A live pending or visible
transaction is preserved and blocks startup. An incomplete *visible* journal is
reported as corruption and is not silently discarded.

## Atomic rack publication and durable package boundary

Before downloading, pouring, or building an inherited replacement, Homebrew
exchanges two private probe directories twice on the active user Cellar. The
probe verifies the selected GNU `mv --exchange` implementation, the kernel, and
the actual deployment filesystem. Unsupported deployments therefore fail before
package work begins.

An inherited replacement proceeds as follows:

1. Build or pour the formula into its transaction staging rack.
2. Relocate staging-prefix references to the final native Cellar path.
3. Prepare a complete replacement rack containing the private keg and exact
   inherited-version links.
4. Revalidate the administrator package generation.
5. Publish the rack with Linux `renameat2(RENAME_EXCHANGE)` on the same
   filesystem.
6. Finish dynamic-linkage repair that changes files inside the private keg.
7. Record the administrator generation in the private keg, remove the
   transaction marker, synchronize the package view, and commit the journal.
8. Run ordinary Homebrew link, service, `etc`, `var`, and formula post-install
   work after the private keg is durable.

The atomic guarantee is deliberately limited to **Cellar rack publication**.
Homebrew link and post-install operations may modify regular files or arbitrary
formula-specific locations and cannot be universally reversed. If one of those
operations fails after the durable package boundary, the private keg remains
installed, matching native Homebrew's installed-but-unlinked or
post-install-failed behavior. The overlay does not restore the administrator rack
beneath stale external side effects. Correct the failure, rerun the relevant
native command, or uninstall the private keg.

Before the durable boundary, exceptions and non-raising `Homebrew.failed?`
states discard an uncommitted private keg or restore the inherited rack.

## Startup recovery

Synchronization acquires the global mutation lock before inspecting recovery
state. It then applies these rules:

- a held transaction owner lock means the transaction is live; preserve it and
  fail the concurrent invocation;
- an unlocked hidden `.new-<id>` journal is abandoned setup and is removed with
  transaction-owned staging/replacement paths;
- an unlocked orphan owner-lock file with no journal is removed;
- a complete visible journal is recovered according to its durable state;
- an incomplete or unsafe visible journal is a hard error and all evidence is
  retained;
- a dirty generation with no live owner forces structural package-view
  reconciliation before a clean generation is published.

A private reinstall stores the old keg under an owner-locked
`Cellar/.homebrew-overlay-failed/reinstall-*` control path rather than a
version-looking live rack entry. Recovery preserves a live owner, keeps a new keg
that has crossed the durable base-generation boundary, and otherwise restores the
old keg. Private uninstall removes `opt`, linked-keg, alias, and old-name records
before deleting the keg, so interruption leaves an installed-but-unlinked keg or
an inherited fallback instead of broken namespace records.

Recovery never identifies ownership from a PID alone and never accepts a caller
supplied owner token unless the corresponding advisory lock is actually held.

## Package generations and drift

Both native prefixes contain an explicit package generation:

```text
/home/linuxbrew/.linuxbrew/var/homebrew/overlay-generation
$HOME/.linuxbrew/var/homebrew/overlay-generation
```

The value is a validated 64-character lowercase hexadecimal token. A developer
invocation compares the two generations with its last committed view stamp. When
they match, no dirty marker or recovery journal exists, and the state files are
safe, startup normally returns without traversing either Cellar. When a
generation changes, Homebrew rebuilds the inherited Cellar, `opt`, and linked-keg
view and commits a new stamp.

Normal commands do not perform a calendar-based structural scan. To detect
administrator changes made outside the patched generation protocol without
adding work to interactive shell startup, schedule the explicit forced sync with
the user's crontab:

```cron
17 3 * * * /home/linuxbrew/.linuxbrew/bin/brew overlay-sync
```

Install the entry in each developer's own crontab, never root's, and stagger the
minute across large multi-user systems. Use the actual administrator `bin/brew`
path when the base prefix differs. The launcher reads the same inline, user, and
system overlay configuration before redirecting into the user prefix.
`brew overlay-sync` then uses the existing synchronization and mutation locks and
performs a full structural reconciliation. It does not update repositories,
install packages, or write the administrator prefix. Generation changes made
through the patched `brew` still converge immediately on the next ordinary
invocation.

A pin to a private keg remains pointed at that user-owned keg across cron
reconciliation and administrator generation changes; synchronization never
repoints or silently removes it. A pin does not freeze the inherited dependency
closure, so base-generation drift is still reported by startup and `brew doctor`.
Review or reinstall affected private formulae explicitly rather than rebuilding
or unpinning them from cron.

Administrator package changes should be made through this patched `brew`. After
a manual change that bypasses it, regenerating the administrator package token
remains the immediate path:

```sh
/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/utils/overlay.sh \
  --bump-generation /home/linuxbrew/.linuxbrew
```

Each private keg records the administrator generation against which it was
installed. A later administrator-generation change is reported by startup and
`brew doctor`. Reinstall reported private formulae before relying on binary or
ABI compatibility.

## Managed state

Overlay-owned user state is confined to `$HOME/.linuxbrew`:

```text
var/homebrew/overlay-generation
var/homebrew/overlay-generation.dirty
var/homebrew/locks/overlay-mutation.lock
var/homebrew/locks/overlay-sync.lock
var/homebrew/overlay/base-prefix
var/homebrew/overlay/view.state
var/homebrew/overlay/view.stamp
var/homebrew/overlay/base-drift.state
var/homebrew/overlay/transactions/
var/homebrew/overlay/transactions/.locks/
var/homebrew/overlay/sync/
```

Temporary transaction paths are private descendants of the user Cellar:

```text
Cellar/.homebrew-overlay-staging/<id>/
Cellar/.homebrew-overlay-racks/<id>/
Cellar/.homebrew-overlay-failed/<id>/
Cellar/.homebrew-overlay-failed/reinstall-<pid>-<nonce>/
```

Ruby and shell helpers reject symlinked intermediate state directories. Managed
view state is a NUL-delimited map of normalized relative paths to exact absolute
administrator targets. Synchronization removes a link only when the destination
remains inside the owned user prefix and the current target still matches the
recorded target. A developer-created replacement is not deleted as stale overlay
state.

## Configuration

- `HOMEBREW_OVERLAY=1` enables automatic fallback.
- `HOMEBREW_OVERLAY_BASE_PREFIX` selects the read-only administrator prefix.
- `HOMEBREW_OVERLAY_USER_PREFIX` optionally overrides the default
  `$HOME/.linuxbrew` user prefix.
- `HOMEBREW_OVERLAY_FORCE=1` selects the user prefix even when the invoking user
  can write the base prefix.

These four settings share the overlay-specific `inline > local > system`
precedence. Other Homebrew settings retain their existing `brew.env` precedence.

The base and user prefixes must be absolute and disjoint. The user prefix,
`Cellar`, `Caskroom`, and internal state ancestors must be real owned directories
rather than symlinks. Automatic Homebrew code and tap updates are disabled in an
active user overlay; repository updates, tap maintenance, and administrator base
upgrades remain administrator operations.

## Deployment-branch promotion

The scheduled upstream synchronization rebases into an automation candidate,
runs the complete overlay shell matrix, full RSpec suite, RuboCop, and Sorbet on
the exact candidate SHA, and only then promotes that SHA to `overlay-store` with
an explicit force-with-lease against the previously observed deployment tip.
Repository branch protection and required checks should enforce the same policy
for all other writers.

## Operational boundaries

- `$HOME/.linuxbrew` is not Homebrew's canonical Linux bottle prefix. Bottles
  that are not relocatable may need source builds.
- `renameat2(RENAME_EXCHANGE)` must be supported by the Linux architecture,
  kernel, and deployment filesystem used for the user Cellar. Startup probes the
  exact tool and filesystem before inherited package work begins.
- A developer installation holds a descriptor-validated shared lease on the
  administrator mutation lock through its durable package boundary. Patched
  administrator mutations take that lock exclusively and therefore cannot change
  the lower package layer beneath the build. Changes that bypass the patched
  mutation protocol remain outside this guarantee.
- The generation protocol detects a base change during private publication and
  reports later drift, but it cannot turn out-of-protocol administrator writes
  into an immutable snapshot.
- A base-generation change conservatively marks all private formulae for review,
  even when the changed lower formula appears unrelated.
- The lower package payload is reused through symlinks. This is not a Conda-style
  hardlink cache or a content-addressed store.
- The shared Homebrew repository and shared taps remain administrator-managed and
  read-only to developers.
- Cask inheritance is outside this design.

To disable automatic fallback, remove or override `HOMEBREW_OVERLAY=1` in the
highest-precedence source that sets it. Preserve developer-installed formulae and
configuration before removing `$HOME/.linuxbrew`.

See [Final native-overlay review closure](Native-User-Overlay-Final-Review-Closure.md)
for the finding-by-finding correction record and remaining target-host acceptance
checks.
