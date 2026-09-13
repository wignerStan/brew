# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "overlay"

module Homebrew
  module Cmd
    class OverlaySync < AbstractCommand
      cmd_args do
        description <<~EOS
          Force a structural reconciliation of an active native per-user overlay
          with its administrator package layer. This is intended for periodic
          scheduling, such as a daily cron job, to detect structural base
          additions and removals made outside the patched generation protocol.
        EOS

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
      end
    end
  end
end
