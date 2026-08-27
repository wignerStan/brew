# typed: strict
# frozen_string_literal: true

require "keg"
require "overlay"

# Helper functions for pinning a formula.
class FormulaPin
  sig { params(formula: Formula).void }
  def initialize(formula)
    @formula = formula
  end

  sig { returns(Pathname) }
  def path
    HOMEBREW_PINNED_KEGS/@formula.name
  end

  sig { params(version: PkgVersion).void }
  def pin_at(version)
    unpin if stale?
    version_path = @formula.rack/version.to_s
    return if Homebrew::Overlay.inherited_keg?(version_path)

    HOMEBREW_PINNED_KEGS.mkpath
    path.make_relative_symlink(version_path) if !pinned? && version_path.exist?
  end

  sig { void }
  def pin
    unpin if stale?
    installed_kegs = @formula.installed_kegs.reject do |keg|
      Homebrew::Overlay.inherited_keg?(keg.to_path)
    end
    latest_keg = installed_kegs.max_by(&:scheme_and_version)
    return if latest_keg.nil?

    pin_at(latest_keg.version)
  end

  sig { void }
  def unpin
    path.unlink if path.symlink?
    HOMEBREW_PINNED_KEGS.rmdir_if_possible
  end

  sig { returns(T::Boolean) }
  def pinned?
    return false unless path.symlink? && path.exist?

    !Homebrew::Overlay.inherited_keg?(path.resolved_path)
  rescue SystemCallError
    false
  end

  # A dangling pin and a live pin into the administrator Cellar are both stale:
  # neither can provide a durable user-owned version selection.
  sig { returns(T::Boolean) }
  def stale?
    return false unless path.symlink?
    return true unless path.exist?

    Homebrew::Overlay.inherited_keg?(path.resolved_path)
  rescue SystemCallError
    true
  end

  sig { returns(T::Boolean) }
  def pinnable?
    !@formula.installed_prefixes.empty?
  end

  sig { returns(T.nilable(PkgVersion)) }
  def pinned_version
    Keg.new(path.resolved_path).version if pinned?
  end
end
