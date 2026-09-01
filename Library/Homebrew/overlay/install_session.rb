# typed: strict
# frozen_string_literal: true

module Homebrew
  module Overlay
    # Owns overlay state spanning FormulaInstaller#install and #finish.
    # FormulaInstaller retains native sequencing and delegates only the
    # lower-layer lease, transaction, generation, and recovery lifecycle.
    class InstallSession
      sig { void }
      def initialize
        @formula_name = T.let(nil, T.nilable(String))
        @formula_version = T.let(nil, T.nilable(String))
        @formula_full_name = T.let(nil, T.nilable(String))
        @transaction = T.let(nil, T.nilable(FormulaTransaction))
        @base_generation = T.let(nil, T.nilable(String))
        @local_keg_preexisting = T.let(false, T::Boolean)
        @local_keg_committed = T.let(false, T::Boolean)
        @mutation_owned = T.let(false, T::Boolean)
        @previous_failed = T.let(nil, T.nilable(T::Boolean))
        @base_mutation_lease = T.let(nil, T.nilable(File))
      end

      sig { params(formula: T.untyped).void }
      def start!(formula)
        @formula_name = formula.name
        @formula_version = formula.pkg_version.to_s
        @formula_full_name = formula.full_name

        if Overlay.active?
          @base_mutation_lease = Overlay.acquire_base_mutation_lease
          @local_keg_preexisting = Overlay.local_keg_realization?(formula_name, formula_version)
          generation = Overlay.current_base_generation
          @base_generation = generation
          @transaction = Overlay.begin_formula_transaction(formula, base_generation: generation)
          Overlay.validate_local_install_target!(formula_name, formula_version) if @transaction.nil?
        end

        if Homebrew::EnvConfig.overlay? && !Overlay.mutation_active?
          Overlay.begin_mutation!
          @mutation_owned = true
        end
        return if @base_generation.nil?

        @previous_failed = Homebrew.failed?
        Homebrew.failed = false
      end

      sig { returns(T::Hash[String, String]) }
      def build_environment
        transaction = @transaction
        return {} if transaction.nil?

        { "HOMEBREW_OVERLAY_INSTALL_TRANSACTION_ID" => transaction.id }
      end

      sig { params(sandbox: T.untyped).void }
      def apply_build_sandbox_rules(sandbox)
        transaction = @transaction
        sandbox.allow_read_if_exists(path: transaction.transaction_dir) if transaction
      end

      sig { returns(T::Boolean) }
      def managed?
        !@transaction.nil? || !@base_generation.nil?
      end

      sig { void }
      def validate_install!
        verify_base_generation!
        raise_transaction_failure!
      end

      sig { void }
      def publish!
        verify_base_generation!
        @transaction&.publish!
      end

      sig { params(keg: T.untyped).void }
      def commit!(keg)
        return unless managed?

        raise_transaction_failure!
        if (transaction = @transaction)
          transaction.commit!
        elsif (generation = @base_generation)
          Overlay.verify_base_generation!(generation)
          Overlay.record_base_generation!(keg.to_path, generation)
          Overlay.verify_base_generation!(generation)
          @local_keg_committed = true
          Overlay.bump_generation!
          @mutation_owned = false
        end
        Overlay.mark_reinstall_committed!(formula_name, formula_version, keg.to_path)
      end

      sig { void }
      def complete_native_install!
        return if managed?

        Overlay.bump_generation!
        @mutation_owned = false
      end

      sig { void }
      def abort!
        transaction = @transaction
        transaction.rollback! if transaction && !transaction.finished?
        rollback_uncommitted_local_keg!
      ensure
        finalize_failed_mutation!
      end

      sig { void }
      def close!
        restore_failure_scope!
      ensure
        release_base_mutation_lease!
      end

      private

      sig { returns(String) }
      def formula_name = T.must(@formula_name)

      sig { returns(String) }
      def formula_version = T.must(@formula_version)

      sig { returns(String) }
      def formula_full_name = T.must(@formula_full_name)

      sig { void }
      def verify_base_generation!
        generation = @base_generation
        Overlay.verify_base_generation!(generation) if generation
      end

      sig { returns(T::Boolean) }
      def package_committed?
        @local_keg_committed || @transaction&.finished? || false
      end

      sig { void }
      def raise_transaction_failure!
        return if package_committed?
        return if @base_generation.nil?

        verify_base_generation!
        return unless Homebrew.failed?

        message = [
          "#{formula_full_name} failed before its private keg was committed;",
          "uncommitted package state was discarded",
        ].join(" ")
        raise TransactionFailure, message
      end

      sig { void }
      def rollback_uncommitted_local_keg!
        return unless Overlay.active?
        return if @transaction || @local_keg_preexisting || @local_keg_committed
        return if @base_generation.nil?

        Overlay.discard_local_keg!(formula_name, formula_version)
      end

      sig { void }
      def finalize_failed_mutation!
        return unless @mutation_owned

        begin
          Overlay.sync!(mutation: true) if Overlay.mutation_active?
        ensure
          @mutation_owned = false
        end
      end

      sig { void }
      def restore_failure_scope!
        previous_failed = @previous_failed
        return if previous_failed.nil?

        Homebrew.failed = previous_failed || Homebrew.failed?
        @previous_failed = nil
      end

      sig { void }
      def release_base_mutation_lease!
        lease = @base_mutation_lease
        return if lease.nil?

        @base_mutation_lease = nil
        Overlay.release_base_mutation_lease(lease)
      end
    end
  end
end
