# Native overlay implementation

`Library/Homebrew/overlay.rb` is the stable public loader. Homebrew-owned code
must require only that file and call the public `Homebrew::Overlay` API.

Implementation belongs in this directory so upstream rebases normally touch a
small set of explicit integration seams rather than the overlay state machines.

## Dependency direction

Keep dependencies moving downward:

1. path and value helpers;
2. descriptor-bound I/O, durable filesystem, and lock primitives;
3. generation, view-state, and transaction state machines;
4. install, reinstall, and command adapters;
5. thin calls from upstream-owned Homebrew files.

Lower layers must not require `FormulaInstaller`, command classes, or cleanup
code. Transaction objects should receive the smallest values they need instead
of retaining broad Homebrew objects.

## Durability rules

- Open security-sensitive files without following symlinks and compare the
  path identity with the retained descriptor before and after use.
- Keep long-lived lock descriptors behind the retained-file helper and close
  them only at the owning session or transaction boundary.
- After creating a directory component, fsync its containing directory before
  publishing data beneath it.
- Publish state with write, file fsync, rename, and parent-directory fsync in
  that order.
- Detach recursive cleanup roots into validated tombstones before deletion.

## Rebase rules

- Do not copy complete upstream methods into overlay files.
- Prefer small before/after hooks that preserve the current upstream method.
- Keep overlay policy out of `formula_installer.rb`, `install.rb`, `keg.rb`, and
  `reinstall/reinstall.rb`; those files should only coordinate public overlay
  objects.
- Keep generated RBI changes separate and regenerate them from source.
- Keep behavior changes separate from file moves and mechanical extraction.
- Compare rewritten patch stacks with `git range-diff` after every upstream
  rebase.

## Current extraction state

- `core.rb` is the compatibility implementation boundary for path policy,
  descriptor-bound I/O, durable filesystem operations, locking, generation,
  view state, and transaction recovery. Keep new responsibilities out of this
  file and extract the existing ones behind unchanged public methods.
- `install_session.rb` captures the current formula identity at install start
  and owns the lease, transaction, generation, and failure scope spanning
  `FormulaInstaller#install` and `#finish`.
- `reinstall_session.rb` owns inherited/private reinstall preparation,
  rollback, and commit policy; `reinstall/reinstall.rb` keeps native backup
  behavior and delegates through one overlay session.

Prefer the next extractions in this order: `owned_io.rb`, `durable_fs.rb`,
`lock_lease.rb`, `path_policy.rb`, `formula_transaction.rb`, and
`reinstall_backup.rb`. Preserve public callers and durable state formats while
moving code.
