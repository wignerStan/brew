# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "unlink"
require "overlay"

module Homebrew
  module Cmd
    class UnlinkCmd < AbstractCommand
      cmd_args do
        description <<~EOS
          Remove symlinks for <formula> or <cask> from Homebrew's prefix. This can be
          useful for temporarily disabling a formula:
          `brew unlink` <formula> `&&` <commands> `&& brew link` <formula>
        EOS
        switch "-n", "--dry-run",
               description: "List files which would be unlinked without actually unlinking or " \
                            "deleting any files."
        switch "--formula", "--formulae",
               description: "Treat all named arguments as formulae."
        switch "--cask", "--casks",
               description: "Treat all named arguments as casks."

        conflicts "--formula", "--cask"

        named_args [:installed_formula, :installed_cask], min: 1
      end

      sig { override.void }
      def run
        options = { dry_run: args.dry_run?, verbose: args.verbose? }
        kegs, casks = args.named.to_kegs_to_casks
        if (keg = kegs.find { |candidate| Homebrew::Overlay.base_formula_available?(candidate.name) })
          odie <<~EOS
            `brew unlink #{keg.name}` is unsupported while #{keg.name} has an administrator-base fallback.
            Unlinking the user realization would immediately expose the base executable through PATH.
            Uninstall the user realization to fall back intentionally, or ask an administrator to change the base.
          EOS
        end

        kegs.each do |keg|
          if args.dry_run?
            puts "Would remove:"
            keg.unlink(**options)
            next
          end

          Unlink.unlink(keg, dry_run: args.dry_run?, verbose: args.verbose?)
        end

        casks.each do |cask|
          raise Cask::CaskNotInstalledError, cask unless cask.installed?

          puts "Would remove:" if args.dry_run?
          cask.artifacts.grep(Cask::Artifact::Symlinked).select(&:target_links_to_source?).each do |artifact|
            artifact.uninstall_phase(**options)
          end
        end
      end
    end
  end
end
