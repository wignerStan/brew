# Native overlay implementation

`Library/Homebrew/overlay.rb` is the stable public loader. Homebrew-owned code
must require only that file and call the public `Homebrew::Overlay` API.

Implementation belongs in this directory so upstream rebases normally touch a
small set of explicit integration seams rather than the overlay state machines.

## Dependency direction

Keep dependencies moving downward:

1. path and value helpers;
2. durable filesystem and lock primitives;
3. mutation and transaction state machines;
4. install, reinstall, and command adapters;
5. thin calls from upstream-owned Homebrew files.

Lower layers must not require `FormulaInstaller`, command classes, or cleanup
code. Transaction objects should receive the smallest values they need instead
of retaining broad Homebrew objects.

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

- `core.rb` contains the original subsystem implementation unchanged.
- `install_session.rb` captures the current formula identity at install start
  and owns the lease, transaction, generation, and failure scope spanning
  `FormulaInstaller#install` and `#finish`.
- `reinstall_session.rb` owns inherited/private reinstall preparation,
  rollback, and commit policy; `reinstall/reinstall.rb` now keeps native backup
  behavior and delegates through one overlay session.

Continue extracting focused files behind the stable loader without changing
callers or durable state formats.
