# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "overlay"
require "formula"
require "missing"

module Homebrew
  module Cmd
    class OverlaySync < AbstractCommand
      cmd_args do
        description <<~EOS
          Force a structural reconciliation of an active native per-user overlay
          with its administrator package layer. This is intended for periodic
          scheduling, such as a daily cron job, to detect structural base
          additions and removals made outside the patched generation protocol.
          With --repair, install missing dependencies of private formulae and
          rebuild private formulae with broken library linkage.
        EOS

        switch "--repair",
               description: "Install missing dependencies of local overlay formulae after synchronisation."
        named_args :none
      end

      sig { override.void }
      def run
        unless Homebrew::Overlay.active?
          ofail "`brew overlay-sync` requires an active per-user Homebrew overlay."
          return
        end

        # Overlay.sync! dispatches the force-reconciliation shell entry point.
        Homebrew::Overlay.sync!
        return unless args.flags_only.include?("--repair")

        local_formulae = Formula.installed.select { |formula| Homebrew::Overlay.local_realizations?(formula.name) }
        return if local_formulae.empty?

        dependencies = Homebrew::Missing.deps(local_formulae).values.flatten.uniq.sort
        if dependencies.any?
          unless system(HOMEBREW_BREW_FILE.to_s, "install", "--formula", *dependencies)
            ofail "Could not install missing local overlay dependencies: #{dependencies.join(", ")}."
            return
          end
          Homebrew::Overlay.sync!
        end
        unless system(HOMEBREW_BREW_FILE.to_s, "missing", *local_formulae.map(&:name))
          ofail "Local overlay formulae still have missing dependencies."
          return
        end
        local_formulae.each do |formula|
          next if system(HOMEBREW_BREW_FILE.to_s, "linkage", "--test", formula.name)

          unless system(HOMEBREW_BREW_FILE.to_s, "reinstall", "--formula", formula.name)
            ofail "Could not rebuild local overlay formula with broken linkage: #{formula.name}."
            next
          end
          Homebrew::Overlay.sync!
          ofail "Local overlay formula still has broken linkage: #{formula.name}." unless
            system(HOMEBREW_BREW_FILE.to_s, "linkage", "--test", formula.name)
        end
      end
    end
  end
end
