# typed: strict
# frozen_string_literal: true

module Homebrew
  module Overlay
    # Owns the overlay-specific part of one formula reinstall. Native Homebrew
    # backup behavior stays in Reinstall; this object handles only inherited and
    # private overlay kegs so the upstream-facing method has one narrow seam.
    class ReinstallSession
      extend T::Sig

      sig {
        params(
          keg:      T.untyped,
          link_keg: T::Boolean,
          verbose:  T::Boolean,
        ).returns(T.nilable(ReinstallSession))
      }
      def self.build(keg, link_keg:, verbose:)
        return unless Overlay.active? && keg

        new(keg, link_keg:, verbose:)
      end

      sig { params(keg: T.untyped, link_keg: T::Boolean, verbose: T::Boolean).void }
      def initialize(keg, link_keg:, verbose:)
        @keg = T.let(keg, T.untyped)
        @link_keg = T.let(link_keg, T::Boolean)
        @verbose = T.let(verbose, T::Boolean)
        @inherited = T.let(Overlay.inherited_keg?(@keg.to_path), T::Boolean)
        @backup = T.let(nil, T.nilable(ReinstallBackup))
        @mutation_started = T.let(false, T::Boolean)
      end

      sig { void }
      def prepare!
        if @inherited
          @keg.unlink
          return
        end

        unless Overlay.mutation_active?
          Overlay.begin_mutation!
          @mutation_started = true
        end
        @keg.unlink
        @backup = ReinstallBackup.new(Pathname(@keg.to_path)).start!
      end

      sig { void }
      def rollback!
        if @inherited
          # FormulaInstaller rolls back any staged realization. Rebuild the
          # inherited opt/linked records when failure preceded publication.
          Overlay.sync!
          return
        end

        backup = @backup
        if backup
          if backup.committed_replacement?
            # Keep the committed private keg: later native link or post-install
            # effects are not generally reversible.
            backup.discard!
            Overlay.sync!(mutation: true) if Overlay.mutation_active?
          else
            backup.restore!
            @keg.link(verbose: @verbose) if @link_keg
          end
        elsif @mutation_started && Overlay.mutation_active?
          Overlay.sync!(mutation: true)
        end
      end

      sig { void }
      def commit!
        return if @inherited

        backup = @backup
        return if backup.nil?

        backup.discard!
        Overlay.sync!(mutation: true) if Overlay.mutation_active?
      end
    end
  end
end
