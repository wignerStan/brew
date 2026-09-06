# typed: strict
# frozen_string_literal: true

require "env_config"
require "fileutils"
require "securerandom"
require "utils/popen"

module Homebrew
  # Helpers for the optional non-service package overlay. The active prefix is
  # an ordinary Homebrew layout. Untouched administrator racks are inherited
  # as symlinks; a locally overridden formula uses a real native Cellar rack
  # containing the local keg and read-only links to other base versions.
  module Overlay
    @link_state_entries = T.let(nil, T.nilable(T::Hash[String, String]))
    @install_transactions = T.let({}, T::Hash[String, T.untyped])
    @reinstall_backups = T.let({}, T::Hash[String, T.untyped])
    @mutation_lock = T.let(nil, T.nilable(File))
    @atomic_exchange_supported = T.let(false, T::Boolean)

    class InheritedKegError < RuntimeError
      sig { params(keg_path: Pathname, base_prefix: Pathname).void }
      def initialize(keg_path, base_prefix)
        super <<~EOS
          #{keg_path} is inherited from #{base_prefix} and cannot be modified from the user prefix.
          Reinstall or upgrade the formula to create a writable copy in #{HOMEBREW_PREFIX}.
          Ask an administrator to change the base package itself.
        EOS
      end
    end

    class TransactionFailure < RuntimeError; end

    class BaseGenerationChangedError < TransactionFailure
      sig { params(expected: String, actual: String).void }
      def initialize(expected, actual)
        super <<~EOS
          The administrator Homebrew base changed during this install.
            expected generation: #{expected}
            current generation:  #{actual}
          The local formula was not committed. Retry after the administrator update finishes.
        EOS
      end
    end

    TRANSACTION_MARKER = ".brew-overlay-transaction"
    BASE_GENERATION_MARKER = ".brew-overlay-base-generation"
    BASE_GENERATION_PATTERN = /\A[0-9a-f]{64}\z/
    MUTATION_LOCK_DESCRIPTOR = 198
    TRANSACTION_LOCK_DESCRIPTOR = 199
    MAX_TRANSACTION_MARKER_BYTES = 256
    MAX_MANAGED_STATE_BYTES = T.let(64 * 1024 * 1024, Integer)

    # A durable installation transaction for replacing an inherited formula.
    # Build and pour operations use a staging rack. Publication prepares a
    # complete native rack and uses GNU mv --exchange (backed by Linux
    # renameat2(RENAME_EXCHANGE)) to swap it with the inherited rack in one
    # filesystem operation.
    class FormulaTransaction
      sig { returns(String) }
      attr_reader :formula_name

      sig { returns(String) }
      attr_reader :version

      sig { returns(String) }
      attr_reader :id

      sig { returns(Pathname) }
      attr_reader :transaction_dir

      sig { returns(Pathname) }
      attr_reader :staging_rack

      sig { returns(Pathname) }
      attr_reader :staging_version

      sig { returns(Pathname) }
      attr_reader :replacement_rack

      sig { returns(Pathname) }
      attr_reader :final_rack

      sig { returns(Pathname) }
      attr_reader :final_version

      sig { returns(String) }
      attr_reader :base_generation

      sig { returns(T::Boolean) }
      def finished? = @finished

      sig { returns(File) }
      def owner_lock
        owner_lock = @owner_lock
        if owner_lock.nil? || owner_lock.closed?
          raise TransactionFailure, "overlay transaction owner lock is not open: #{@owner_lock_path}"
        end

        owner_lock
      end

      sig { params(formula: T.untyped, base_generation: String).void }
      def initialize(formula, base_generation:)
        @formula_name = T.let(formula.name, String)
        @version = T.let(formula.pkg_version.to_s, String)
        @base_generation = base_generation
        unless Overlay.valid_formula_name?(@formula_name)
          raise ArgumentError,
                "invalid formula name: #{@formula_name}"
        end
        raise ArgumentError, "invalid formula version: #{@version}" unless Overlay.valid_version_name?(@version)

        Overlay.validate_base_generation!(@base_generation)

        @id = T.let("#{Process.pid}-#{SecureRandom.hex(12)}", String)
        @transaction_dir = T.let(Overlay.transactions_dir/@id, Pathname)
        @pending_transaction_dir = T.let(Overlay.transactions_dir/".new-#{@id}", Pathname)
        @owner_lock_path = T.let(Overlay.transactions_dir/".locks"/"#{@id}.lock", Pathname)
        @owner_lock = T.let(nil, T.nilable(File))
        @staging_root = T.let(HOMEBREW_CELLAR/".homebrew-overlay-staging"/@id, Pathname)
        @staging_rack = T.let(@staging_root/@formula_name, Pathname)
        @staging_version = T.let(@staging_rack/@version, Pathname)
        @replacement_root = T.let(HOMEBREW_CELLAR/".homebrew-overlay-racks"/@id, Pathname)
        @replacement_rack = T.let(@replacement_root/@formula_name, Pathname)
        @final_rack = T.let(HOMEBREW_CELLAR/@formula_name, Pathname)
        @final_version = T.let(@final_rack/@version, Pathname)
        @published = T.let(false, T::Boolean)
        @finished = T.let(false, T::Boolean)
      end

      sig { returns(FormulaTransaction) }
      def start!
        owns_mutation = false
        if transaction_dir.exist? || transaction_dir.symlink? ||
           @pending_transaction_dir.exist? || @pending_transaction_dir.symlink?
          raise TransactionFailure, "overlay transaction already exists: #{transaction_dir}"
        end

        owns_mutation = !Overlay.mutation_active?
        acquire_owner_lock!
        prepare_control_directories!
        Overlay.begin_mutation! if owns_mutation
        Overlay.verify_base_generation!(base_generation)
        Overlay.ensure_inherited_rack!(formula_name)
        publish_journal!
        Overlay.ensure_owned_directory!(staging_rack)
        staging_rack.chmod 0700
        Overlay.register_transaction(self)
        self
      # Cleanup must also restore durable state for Interrupt and SystemExit.
      rescue Exception # rubocop:disable Lint/RescueException
        Overlay.unregister_transaction(formula_name, self)
        begin
          cleanup_paths!
        ensure
          Overlay.sync!(mutation: true) if owns_mutation && Overlay.mutation_active?
        end
        raise
      end

      sig { void }
      def publish!
        return if @published

        valid_staging_version =
          staging_version.directory? &&
          !staging_version.symlink? &&
          staging_version.children.any?
        unless valid_staging_version
          raise TransactionFailure, "staged formula version is missing or empty: #{staging_version}"
        end

        Overlay.verify_base_generation!(base_generation)
        relocate_staging_prefix!
        prepare_replacement_rack!
        Overlay.verify_base_generation!(base_generation)
        write_state("publishing")
        Overlay.atomic_exchange!(final_rack, replacement_rack)
        write_state("published")
        @published = true
        Overlay.unregister_transaction(formula_name, self)
        Overlay.clear_caches!
      # Cleanup must also restore durable state for Interrupt and SystemExit.
      rescue Exception # rubocop:disable Lint/RescueException
        rollback!
        raise
      end

      sig { void }
      def commit!
        return if @finished
        raise TransactionFailure, "overlay transaction was not published" unless transaction_owns_final?

        Overlay.verify_base_generation!(base_generation)
        Overlay.fsync_tree!(final_version)
        Overlay.verify_base_generation!(base_generation)
        Overlay.record_base_generation!(final_version, base_generation)
        Overlay.verify_base_generation!(base_generation)
        write_state("committing")
        Overlay.mark_reinstall_committed!(formula_name, version, final_version)
        marker = final_version/TRANSACTION_MARKER
        Overlay.durable_unlink!(marker)
        write_state("committed")
        @finished = true
        Overlay.clear_caches!
        Overlay.sync!(mutation: true, owner_transaction: self)
        cleanup_paths!
      end

      sig { void }
      def rollback!
        return if @finished

        Overlay.unregister_transaction(formula_name, self)
        write_state("rolling-back") if transaction_dir.directory?

        if transaction_owns_final?
          Overlay.remove_links_to!(final_version)
          Overlay.atomic_exchange!(final_rack, replacement_rack)
        elsif !transaction_owns_replacement? && @published
          raise TransactionFailure, "refusing to roll back an unowned formula rack: #{final_rack}"
        end

        Overlay.clear_caches!
        Overlay.sync!(mutation: true, owner_transaction: self)
        cleanup_paths!
        @finished = true
      end

      private

      sig { params(path: Pathname).returns(T::Boolean) }
      def marker_owned?(path)
        marker = path/TRANSACTION_MARKER
        contents = Overlay.read_owned_file(
          marker,
          description: "overlay formula transaction marker",
          max_bytes:   MAX_TRANSACTION_MARKER_BYTES,
        )
        contents == "#{id}\n"
      end

      sig { returns(T::Boolean) }
      def transaction_owns_final?
        final_version.directory? && !final_version.symlink? && marker_owned?(final_version)
      end

      sig { returns(T::Boolean) }
      def transaction_owns_replacement?
        candidate = replacement_rack/version
        candidate.directory? && !candidate.symlink? && marker_owned?(candidate)
      end

      sig { void }
      def acquire_owner_lock!
        if transaction_dir.exist? || transaction_dir.symlink? ||
           @pending_transaction_dir.exist? || @pending_transaction_dir.symlink?
          raise TransactionFailure, "overlay transaction already exists: #{transaction_dir}"
        end

        lock_dir = @owner_lock_path.parent
        Overlay.ensure_owned_directory!(lock_dir)
        lock_dir.chmod 0700
        if @owner_lock_path.symlink? || @owner_lock_path.exist?
          raise TransactionFailure, "overlay transaction owner lock already exists: #{@owner_lock_path}"
        end

        flags = File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW
        owner_lock = Overlay.open_retained_file(@owner_lock_path, flags, mode: 0600)
        @owner_lock = owner_lock
        stat = owner_lock.stat
        safe_lock = stat.file? && stat.uid == Process.uid && stat.nlink == 1
        unless safe_lock
          raise TransactionFailure, "unsafe overlay transaction owner lock: #{@owner_lock_path}"
        end
        return if owner_lock.flock(File::LOCK_EX | File::LOCK_NB)

        raise TransactionFailure, "could not acquire overlay transaction owner lock: #{@owner_lock_path}"
      end

      sig { void }
      def release_owner_lock!
        owner_lock = @owner_lock
        return if owner_lock.nil?

        owner_lock.flock(File::LOCK_UN) unless owner_lock.closed?
        owner_lock.close unless owner_lock.closed?
        @owner_lock = nil
      end

      sig { void }
      def prepare_control_directories!
        Overlay.ensure_owned_directory!(@staging_root.parent)
        Overlay.ensure_owned_directory!(@replacement_root.parent)
        Overlay.ensure_owned_directory!(Overlay.transactions_dir)
        Overlay.ensure_owned_directory!(@owner_lock_path.parent)
      end

      sig { void }
      def validate_owner_lock_path!
        owner_lock = @owner_lock
        if owner_lock.nil? || owner_lock.closed?
          raise TransactionFailure,
                "overlay transaction owner lock is not open: #{@owner_lock_path}"
        end
        if @owner_lock_path.symlink? || !@owner_lock_path.file?
          raise TransactionFailure, "unsafe overlay transaction owner lock: #{@owner_lock_path}"
        end

        descriptor_stat = owner_lock.stat
        path_stat = @owner_lock_path.lstat
        safe_lock = descriptor_stat.file? && descriptor_stat.uid == Process.uid && descriptor_stat.nlink == 1 &&
                    path_stat.file? && path_stat.uid == Process.uid && path_stat.nlink == 1 &&
                    descriptor_stat.dev == path_stat.dev && descriptor_stat.ino == path_stat.ino
        return if safe_lock

        raise TransactionFailure, "unsafe overlay transaction owner lock: #{@owner_lock_path}"
      end

      sig { params(directory: Pathname, name: String, value: String, exclusive: T::Boolean).void }
      def write_metadata_at(directory, name, value, exclusive:)
        path = directory/name
        if exclusive
          flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
          File.open(path, flags, 0600) do |file|
            file.chmod 0600
            file.write("#{value}\n")
            file.flush
            file.fsync
          end
        else
          Overlay.durable_atomic_write!(path, "#{value}\n", mode: 0600)
        end
      end

      # Build a complete journal under a hidden name, fsync it, then publish it
      # with one directory rename. Recovery therefore sees either no journal or
      # all required metadata; it never mistakes a process killed during setup
      # for a corrupt visible transaction.
      sig { void }
      def publish_journal!
        if transaction_dir.exist? || transaction_dir.symlink? ||
           @pending_transaction_dir.exist? || @pending_transaction_dir.symlink?
          raise TransactionFailure, "overlay transaction already exists: #{transaction_dir}"
        end

        Overlay.ensure_owned_directory!(@pending_transaction_dir)
        @pending_transaction_dir.chmod 0700
        write_metadata_at(@pending_transaction_dir, "formula", formula_name, exclusive: true)
        write_metadata_at(@pending_transaction_dir, "version", version, exclusive: true)
        write_metadata_at(@pending_transaction_dir, "base_generation", base_generation, exclusive: true)
        write_metadata_at(@pending_transaction_dir, "state", "staging", exclusive: true)
        Overlay.fsync_directory!(@pending_transaction_dir)

        raise TransactionFailure, "overlay transaction already exists: #{transaction_dir}" if
          transaction_dir.exist? || transaction_dir.symlink?

        File.rename(@pending_transaction_dir, transaction_dir)
        Overlay.fsync_directory!(Overlay.transactions_dir)
        Overlay.fsync_directory!(Overlay.transactions_dir.parent)
      end

      sig { params(name: String, value: String).void }
      def write_metadata(name, value)
        write_metadata_at(transaction_dir, name, value, exclusive: false)
      end

      sig { params(value: String).void }
      def write_state(value)
        write_metadata("state", value)
      end

      sig { void }
      def prepare_replacement_rack!
        if replacement_rack.exist?
          raise TransactionFailure,
                "overlay replacement rack already exists: #{replacement_rack}"
        end

        Overlay.ensure_owned_directory!(replacement_rack)
        replacement_rack.chmod 0700
        base_rack = Overlay.base_cellar/formula_name
        base_rack.children.each do |base_version|
          real_base_version = base_version.directory? && !base_version.symlink?
          next unless real_base_version
          next if base_version.basename.to_s == version

          File.symlink(base_version, replacement_rack/base_version.basename)
        end

        File.rename(staging_version, replacement_rack/version)
        marker = replacement_rack/version/TRANSACTION_MARKER
        Overlay.durable_atomic_write!(marker, "#{id}\n", mode: 0600)
        Overlay.fsync_directory!(staging_rack)
        Overlay.fsync_directory!(replacement_rack)
        Overlay.fsync_directory!(@replacement_root)
        Overlay.fsync_directory!(@replacement_root.parent)
        Overlay.fsync_directory!(@replacement_root.parent.parent)
      end

      # Formulae built from source may embed Formula#prefix. During an overlay
      # transaction that is the staging path, not the path that will be
      # published. Relocate those references before the atomic rack exchange so
      # the resulting keg is indistinguishable from one built in the native
      # Cellar path.
      sig { void }
      def relocate_staging_prefix!
        old_prefix = staging_version.to_s
        new_prefix = final_version.to_s
        if new_prefix.bytesize > old_prefix.bytesize
          raise TransactionFailure, "overlay staging prefix is shorter than its final prefix"
        end

        require "keg"
        keg = Keg.new(staging_version)
        relocation = Keg::Relocation.new
        relocation.add_replacement_pair(:prefix, old_prefix, new_prefix)
        relocation.freeze
        keg.relocate_dynamic_linkage(relocation)
        keg.replace_text_in_files(relocation)

        # Preserve hardlinks while replacing any remaining text or script
        # occurrence omitted by Homebrew's normal text-file classifier.
        remaining = T.let([], T::Array[Pathname])
        keg.each_unique_file_matching(old_prefix) { |file| remaining << file }
        remaining.each do |file|
          if keg.binary_file?(file) && !file.text_executable?
            raise TransactionFailure, "unrelocated staging path remains in binary: #{file}"
          end

          contents = File.binread(file)
          next unless contents.include?(old_prefix)

          contents.gsub!(old_prefix, new_prefix)
          file.ensure_writable do
            File.binwrite(file, contents)
          end
        end

        staging_version.find do |path|
          next unless path.symlink?

          target = path.readlink
          next unless target.absolute?

          staged_prefix_target = target.to_s == old_prefix || target.to_s.start_with?("#{old_prefix}/")
          next unless staged_prefix_target

          replacement = target.to_s.sub(/\A#{Regexp.escape(old_prefix)}/, new_prefix)
          path.unlink
          File.symlink(replacement, path)
        end

        unresolved = T.let([], T::Array[Pathname])
        keg.each_unique_file_matching(old_prefix) { |file| unresolved << file }
        return if unresolved.empty?

        raise TransactionFailure, "staging path remains after relocation: #{unresolved.first}"
      end

      sig { void }
      def cleanup_paths!
        prepare_control_directories!
        owner_lock_present = @owner_lock_path.exist? || @owner_lock_path.symlink?
        validate_owner_lock_path! if owner_lock_present
        remove_tree_durable!(@staging_root)
        remove_tree_durable!(@replacement_root)
        remove_tree_durable!(@pending_transaction_dir)
        remove_tree_durable!(transaction_dir)
        if owner_lock_present
          validate_owner_lock_path!
          @owner_lock_path.unlink
          Overlay.fsync_directory!(@owner_lock_path.parent)
        end
      ensure
        owner_lock_path_present = @owner_lock_path.exist? || @owner_lock_path.symlink?
        release_owner_lock! unless owner_lock_path_present
      end

      sig { params(path: Pathname).void }
      def remove_tree_durable!(path)
        Overlay.remove_tree_durable!(path)
      end
    end

    # Crash-recoverable backup for replacing an existing private keg. The old
    # keg is moved out of the live rack under an owner-locked hidden control
    # path, so synchronization cannot mistake a transient `.reinstall` version
    # for an intentional package realization.
    class ReinstallBackup
      sig { returns(String) }
      attr_reader :id

      sig { returns(String) }
      attr_reader :formula_name

      sig { returns(String) }
      attr_reader :version

      sig { returns(Pathname) }
      attr_reader :backup_version

      sig { params(keg_path: Pathname).void }
      def initialize(keg_path)
        keg_path = keg_path.expand_path
        @formula_name = T.let(keg_path.parent.basename.to_s, String)
        @version = T.let(keg_path.basename.to_s, String)
        safe_keg = Overlay.local_keg_realization?(@formula_name, @version) &&
                   keg_path.stat.uid == Process.uid
        raise TransactionFailure, "refusing to back up a non-local overlay keg: #{keg_path}" unless safe_keg

        @id = T.let("reinstall-#{Process.pid}-#{SecureRandom.hex(8)}", String)
        @root = T.let(HOMEBREW_CELLAR/".homebrew-overlay-failed"/@id, Pathname)
        @metadata_formula = T.let(@root/"formula", Pathname)
        @metadata_version = T.let(@root/"version", Pathname)
        @metadata_state = T.let(@root/"state", Pathname)
        @metadata_base_generation = T.let(@root/"committed_base_generation", Pathname)
        @metadata_replacement_device = T.let(@root/"committed_device", Pathname)
        @metadata_replacement_inode = T.let(@root/"committed_inode", Pathname)
        @owner_lock_path = T.let(@root/"owner.lock", Pathname)
        @backup_version = T.let(@root/"backup"/@formula_name/@version, Pathname)
        @final_rack = T.let(HOMEBREW_CELLAR/@formula_name, Pathname)
        @final_version = T.let(@final_rack/@version, Pathname)
        @owner_lock = T.let(nil, T.nilable(File))
        @finished = T.let(false, T::Boolean)
      end

      sig { returns(ReinstallBackup) }
      def start!
        Overlay.begin_mutation! unless Overlay.mutation_active?
        Overlay.ensure_owned_directory!(@root)
        @root.chmod 0700
        acquire_owner_lock!
        Overlay.durable_atomic_write!(@metadata_formula, "#{formula_name}\n", mode: 0600)
        Overlay.durable_atomic_write!(@metadata_version, "#{version}\n", mode: 0600)
        Overlay.durable_atomic_write!(@metadata_state, "prepared\n", mode: 0600)
        Overlay.ensure_owned_directory!(backup_version.parent)
        backup_version.parent.chmod 0700
        Overlay.fsync_directory!(@root)

        File.rename(@final_version, backup_version)
        Overlay.fsync_directory!(@final_rack)
        Overlay.fsync_directory!(backup_version.parent)
        Overlay.durable_atomic_write!(@metadata_state, "backed-up\n", mode: 0600)
        Overlay.clear_caches!
        Overlay.register_reinstall_backup(self)
        self
      # Rescue Exception intentionally so recovery runs before non-StandardError interrupts are re-raised.
      # Cleanup must also restore durable state for Interrupt and SystemExit.
      rescue Exception # rubocop:disable Lint/RescueException
        begin
          if backup_version.directory? && !backup_version.symlink? &&
             !@final_version.exist? && !@final_version.symlink?
            File.rename(backup_version, @final_version)
            Overlay.fsync_directory!(@final_rack)
          end
          cleanup_control_root!
        ensure
          Overlay.unregister_reinstall_backup(self)
          release_owner_lock!
        end
        raise
      end

      sig { params(keg_path: Pathname).void }
      def mark_committed!(keg_path)
        state = validate_control_state!
        return if state == "committed" && committed_replacement?
        if state != "backed-up"
          raise TransactionFailure, "overlay reinstall cannot commit from state #{state.inspect}: #{@root}"
        end

        candidate = keg_path.expand_path
        replacement_available =
          candidate == @final_version &&
          Overlay.local_keg_realization?(formula_name, version)
        unless replacement_available
          raise TransactionFailure, "overlay reinstall replacement is unavailable: #{candidate}"
        end

        replacement_stat = candidate.lstat
        safe_replacement = replacement_stat.directory? && replacement_stat.uid == Process.uid
        raise TransactionFailure, "unsafe overlay reinstall replacement: #{candidate}" unless safe_replacement

        marker = candidate/BASE_GENERATION_MARKER
        contents = Overlay.read_owned_file(
          marker,
          description: "administrator base-generation marker",
          max_bytes:   65,
        )
        if contents.nil?
          raise TransactionFailure, "overlay reinstall replacement has no base-generation marker: #{candidate}"
        end

        generation = contents.chomp
        Overlay.validate_base_generation!(generation)
        if contents != "#{generation}\n"
          raise TransactionFailure, "invalid overlay reinstall base-generation marker: #{marker}"
        end

        Overlay.durable_atomic_write!(@metadata_base_generation, "#{generation}\n", mode: 0600)
        Overlay.durable_atomic_write!(@metadata_replacement_device, "#{replacement_stat.dev}\n", mode: 0600)
        Overlay.durable_atomic_write!(@metadata_replacement_inode, "#{replacement_stat.ino}\n", mode: 0600)
        Overlay.durable_atomic_write!(@metadata_state, "committed\n", mode: 0600)
        Overlay.fsync_directory!(@root)
      end

      sig { returns(T::Boolean) }
      def committed_replacement?
        state = Overlay.read_owned_file(
          @metadata_state,
          description: "overlay reinstall state",
          max_bytes:   32,
        )
        return false if state != "committed\n"

        generation = Overlay.read_owned_file(
          @metadata_base_generation,
          description: "overlay reinstall committed base generation",
          max_bytes:   65,
        )
        device = Overlay.read_owned_file(
          @metadata_replacement_device,
          description: "overlay reinstall committed device",
          max_bytes:   32,
        )
        inode = Overlay.read_owned_file(
          @metadata_replacement_inode,
          description: "overlay reinstall committed inode",
          max_bytes:   32,
        )
        complete_metadata =
          generation&.match?(/\A[0-9a-f]{64}\n\z/) &&
          device&.match?(/\A[0-9]+\n\z/) &&
          inode&.match?(/\A[0-9]+\n\z/)
        unless complete_metadata
          raise TransactionFailure, "incomplete committed overlay reinstall metadata: #{@root}"
        end

        recorded_generation = generation.chomp
        Overlay.validate_base_generation!(recorded_generation)
        unless Overlay.local_keg_realization?(formula_name, version)
          raise TransactionFailure, "committed overlay reinstall replacement is missing: #{@final_version}"
        end

        replacement_stat = @final_version.lstat
        expected_identity = [device.to_i, inode.to_i]
        actual_identity = [replacement_stat.dev, replacement_stat.ino]
        if actual_identity != expected_identity
          raise TransactionFailure, "committed overlay reinstall replacement changed: #{@final_version}"
        end

        marker = @final_version/BASE_GENERATION_MARKER
        if marker.exist? || marker.symlink?
          contents = Overlay.read_owned_file(
            marker,
            description: "administrator base-generation marker",
            max_bytes:   65,
          )
          if contents != "#{recorded_generation}\n"
            raise TransactionFailure, "committed overlay reinstall marker changed: #{marker}"
          end
        end
        true
      end

      sig { void }
      def restore!
        return if @finished

        Overlay.begin_mutation! unless Overlay.mutation_active?
        state = validate_control_state!
        if state == "committed"
          raise TransactionFailure, "refusing to restore a committed overlay reinstall: #{@root}"
        end

        prepare_final_rack!
        if @final_version.symlink?
          expected = Overlay.base_cellar/formula_name/version
          if @final_version.readlink != expected
            raise TransactionFailure, "refusing to replace an unexpected overlay reinstall target: #{@final_version}"
          end

          @final_version.unlink
        elsif @final_version.exist?
          safe_final_version = @final_version.directory? && @final_version.stat.uid == Process.uid
          unless safe_final_version
            raise TransactionFailure, "refusing to replace an unsafe overlay reinstall target: #{@final_version}"
          end

          Overlay.remove_links_to!(@final_version)
          final_stat = @final_version.lstat
          Overlay.remove_tree_durable!(
            @final_version,
            expected_device: final_stat.dev,
            expected_inode:  final_stat.ino,
          )
        end

        File.rename(backup_version, @final_version)
        Overlay.fsync_directory!(@final_rack)
        Overlay.fsync_directory!(backup_version.parent)
        Overlay.clear_caches!
        cleanup_control_root!
        @finished = true
        Overlay.sync!(mutation: true)
      ensure
        release_owner_lock! if @finished || (!@root.exist? && !@root.symlink?)
      end

      sig { void }
      def discard!
        return if @finished

        validate_control_state!
        cleanup_control_root!
        @finished = true
      ensure
        release_owner_lock! if @finished || (!@root.exist? && !@root.symlink?)
      end

      private

      sig { void }
      def acquire_owner_lock!
        flags = File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW
        lock = Overlay.open_retained_file(@owner_lock_path, flags, mode: 0600)
        stat = lock.stat
        safe_lock = stat.file? && stat.uid == Process.uid && stat.nlink == 1
        unless safe_lock
          lock.close
          raise TransactionFailure, "could not acquire overlay reinstall owner lock: #{@owner_lock_path}"
        end
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          lock.close
          raise TransactionFailure, "could not acquire overlay reinstall owner lock: #{@owner_lock_path}"
        end
        @owner_lock = lock
        Overlay.fsync_directory!(@root)
      end

      sig { void }
      def release_owner_lock!
        lock = @owner_lock
        return if lock.nil?

        lock.flock(File::LOCK_UN) unless lock.closed?
        lock.close unless lock.closed?
        @owner_lock = nil
      end

      sig { returns(String) }
      def validate_control_state!
        lock = @owner_lock
        if lock.nil? || lock.closed? || @owner_lock_path.symlink? || !@owner_lock_path.file?
          raise TransactionFailure, "unsafe overlay reinstall owner lock: #{@owner_lock_path}"
        end

        descriptor_stat = lock.stat
        path_stat = @owner_lock_path.lstat
        safe_lock = descriptor_stat.file? && descriptor_stat.uid == Process.uid && descriptor_stat.nlink == 1 &&
                    path_stat.file? && path_stat.uid == Process.uid && path_stat.nlink == 1 &&
                    descriptor_stat.dev == path_stat.dev && descriptor_stat.ino == path_stat.ino
        raise TransactionFailure, "changed overlay reinstall owner lock: #{@owner_lock_path}" unless safe_lock

        formula = Overlay.read_owned_file(
          @metadata_formula,
          description: "overlay reinstall formula",
          max_bytes:   256,
        )
        recorded_version = Overlay.read_owned_file(
          @metadata_version,
          description: "overlay reinstall version",
          max_bytes:   256,
        )
        state = Overlay.read_owned_file(
          @metadata_state,
          description: "overlay reinstall state",
          max_bytes:   32,
        )
        valid_metadata = formula == "#{formula_name}\n" && recorded_version == "#{version}\n" &&
                         ["prepared\n", "backed-up\n", "committed\n"].include?(state)
        raise TransactionFailure, "invalid overlay reinstall metadata: #{@root}" unless valid_metadata

        safe_backup = backup_version.directory? && !backup_version.symlink? && backup_version.stat.uid == Process.uid
        raise TransactionFailure, "overlay reinstall backup is unavailable: #{backup_version}" unless safe_backup

        T.must(state).chomp
      end

      sig { void }
      def prepare_final_rack!
        expected_base_rack = Overlay.base_cellar/formula_name
        if @final_rack.symlink?
          if @final_rack.readlink != expected_base_rack
            raise TransactionFailure, "refusing to replace a non-inherited formula rack: #{@final_rack}"
          end

          @final_rack.unlink
          Overlay.ensure_owned_directory!(@final_rack)
        elsif !@final_rack.exist?
          Overlay.ensure_owned_directory!(@final_rack)
        elsif !@final_rack.directory? || @final_rack.stat.uid != Process.uid
          raise TransactionFailure, "unsafe overlay reinstall rack: #{@final_rack}"
        end
      end

      sig { void }
      def cleanup_control_root!
        managed_root = @root.exist? || @root.symlink?
        unless managed_root
          Overlay.unregister_reinstall_backup(self)
          return
        end

        root_stat = @root.lstat
        safe_root = root_stat.directory? && !@root.symlink? && root_stat.uid == Process.uid
        raise TransactionFailure, "unsafe overlay reinstall control path: #{@root}" unless safe_root

        Overlay.remove_tree_durable!(
          @root,
          expected_device: root_stat.dev,
          expected_inode:  root_stat.ino,
        )
      ensure
        control_root_removed = !@root.exist? && !@root.symlink?
        Overlay.unregister_reinstall_backup(self) if control_root_removed
      end
    end

    private_constant :TRANSACTION_MARKER, :BASE_GENERATION_PATTERN

    sig { returns(T::Boolean) }
    def self.active?
      Homebrew::EnvConfig.overlay_active?
    end

    sig { returns(Pathname) }
    def self.base_prefix
      value = Homebrew::EnvConfig.overlay_base_prefix
      if value.blank?
        raise "HOMEBREW_OVERLAY_BASE_PREFIX is required for an active overlay"
      end

      Pathname(value).expand_path
    end

    sig { returns(Pathname) }
    def self.base_cellar
      base_prefix/"Cellar"
    end

    sig { returns(Pathname) }
    def self.transactions_dir
      HOMEBREW_PREFIX/"var/homebrew/overlay/transactions"
    end

    sig { params(name: String).returns(T::Boolean) }
    def self.valid_formula_name?(name)
      name.match?(/\A[A-Za-z0-9][A-Za-z0-9@+._-]*\z/)
    end

    sig { params(version: String).returns(T::Boolean) }
    def self.valid_version_name?(version)
      !version.empty? && version != "." && version != ".." && version.match?(%r{\A[^/\0\r\n]+\z})
    end

    sig { params(path: Pathname, flags: Integer, mode: T.nilable(Integer)).returns(File) }
    def self.open_retained_file(path, flags, mode: nil)
      retained = T.let(nil, T.nilable(File))
      completed = false
      begin
        retained = if mode.nil?
          File.open(path, flags, &:dup)
        else
          File.open(path, flags, mode, &:dup)
        end
        descriptor = retained
        descriptor.close_on_exec = true
        completed = true
        descriptor
      ensure
        retained.close if !completed && retained && !retained.closed?
      end
    end

    sig {
      params(
        path:        Pathname,
        description: String,
        max_bytes:   Integer,
      ).returns(T.nilable(String))
    }
    def self.read_owned_file(path, description:, max_bytes:)
      flags = File::RDONLY | File::NOFOLLOW
      file = begin
        open_retained_file(path, flags)
      rescue Errno::ENOENT
        nil
      end
      return if file.nil?

      begin
        file.binmode
        descriptor_stat = file.stat
        path_stat = path.lstat
        safe_descriptor = descriptor_stat.file? &&
                          descriptor_stat.uid == Process.uid &&
                          descriptor_stat.nlink == 1 &&
                          descriptor_stat.mode.nobits?(0022) &&
                          descriptor_stat.dev == path_stat.dev &&
                          descriptor_stat.ino == path_stat.ino
        raise TransactionFailure, "unsafe #{description}: #{path}" unless safe_descriptor
        if descriptor_stat.size > max_bytes
          raise TransactionFailure, "oversized #{description}: #{path}"
        end

        contents = file.read(max_bytes + 1) || ""
        final_descriptor_stat = file.stat
        final_path_stat = path.lstat
        stable_descriptor = descriptor_stat.dev == final_descriptor_stat.dev &&
                            descriptor_stat.ino == final_descriptor_stat.ino &&
                            descriptor_stat.mode == final_descriptor_stat.mode &&
                            descriptor_stat.uid == final_descriptor_stat.uid &&
                            descriptor_stat.gid == final_descriptor_stat.gid &&
                            descriptor_stat.nlink == final_descriptor_stat.nlink &&
                            descriptor_stat.size == final_descriptor_stat.size &&
                            descriptor_stat.mtime == final_descriptor_stat.mtime &&
                            descriptor_stat.ctime == final_descriptor_stat.ctime
        stable_path = final_descriptor_stat.dev == final_path_stat.dev &&
                      final_descriptor_stat.ino == final_path_stat.ino &&
                      final_descriptor_stat.mode == final_path_stat.mode &&
                      final_descriptor_stat.uid == final_path_stat.uid &&
                      final_descriptor_stat.nlink == final_path_stat.nlink
        stable_read = stable_descriptor &&
                      stable_path &&
                      contents.bytesize == descriptor_stat.size &&
                      contents.bytesize <= max_bytes
        raise TransactionFailure, "changed #{description} while reading: #{path}" unless stable_read

        contents
      ensure
        file.close unless file.closed?
      end
    rescue TransactionFailure
      raise
    rescue SystemCallError, IOError => e
      raise TransactionFailure, "unsafe #{description}: #{path} (#{e.message})"
    end

    sig { params(path: Pathname).returns(Pathname) }
    def self.canonical_path(path)
      path.realpath
    rescue Errno::ENOENT, Errno::EACCES
      path.expand_path
    end

    sig { params(path: Pathname, root: Pathname).returns(T::Boolean) }
    def self.path_under?(path, root)
      path = path.expand_path
      root = root.expand_path
      path == root || path.to_s.start_with?("#{root}/")
    end

    # Create a private internal directory without following any symlinked
    # component below the native prefix. Every new directory entry is published
    # by fsyncing its already-validated parent before deeper paths are created.
    sig { params(directory: Pathname).void }
    def self.ensure_owned_directory!(directory)
      prefix = HOMEBREW_PREFIX.expand_path
      directory = directory.expand_path
      safe_prefix = prefix.directory? && !prefix.symlink? && prefix.stat.uid == Process.uid && prefix.writable?
      raise TransactionFailure, "unsafe or non-writable Homebrew overlay prefix: #{prefix}" unless safe_prefix
      unless path_under?(directory, prefix)
        raise TransactionFailure, "overlay directory escapes the native prefix: #{directory}"
      end

      relative = directory.relative_path_from(prefix)
      current = prefix
      relative.each_filename do |component|
        valid_component = !component.empty? && component != "." && component != ".."
        raise TransactionFailure, "invalid overlay directory component: #{directory}" unless valid_component

        parent = current
        current /= component
        if current.symlink? || (current.exist? && !current.directory?)
          raise TransactionFailure, "unsafe overlay directory component: #{current}"
        end

        unless current.directory?
          parent_stat = parent.lstat
          safe_parent = parent_stat.directory? && !parent.symlink? &&
                        parent_stat.uid == Process.uid && parent.writable?
          raise TransactionFailure, "unsafe overlay directory parent: #{parent}" unless safe_parent

          current.mkdir
          fsync_directory!(parent, expected_device: parent_stat.dev, expected_inode: parent_stat.ino)
        end
        safe_directory = current.directory? && !current.symlink? &&
                         current.stat.uid == Process.uid && current.writable?
        unless safe_directory
          raise TransactionFailure, "unowned or non-writable overlay directory: #{current}"
        end
      end
    rescue ArgumentError
      raise TransactionFailure, "overlay directory escapes the native prefix: #{directory}"
    end

    sig {
      params(
        directory:       Pathname,
        expected_device: T.nilable(Integer),
        expected_inode:  T.nilable(Integer),
      ).void
    }
    def self.fsync_directory!(directory, expected_device: nil, expected_inode: nil)
      directory = directory.expand_path
      flags = File::RDONLY | File::NOFOLLOW
      File.open(directory, flags) do |file|
        descriptor_stat = file.stat
        path_stat = directory.lstat
        expected_identity = (expected_device.nil? && expected_inode.nil?) ||
                            (descriptor_stat.dev == expected_device && descriptor_stat.ino == expected_inode)
        safe_directory = descriptor_stat.directory? && descriptor_stat.uid == Process.uid &&
                         path_stat.directory? && path_stat.uid == Process.uid &&
                         descriptor_stat.dev == path_stat.dev && descriptor_stat.ino == path_stat.ino &&
                         expected_identity
        raise TransactionFailure, "unsafe overlay durability directory: #{directory}" unless safe_directory

        file.fsync
        final_descriptor_stat = file.stat
        final_path_stat = directory.lstat
        stable_directory = descriptor_stat.dev == final_descriptor_stat.dev &&
                           descriptor_stat.ino == final_descriptor_stat.ino &&
                           descriptor_stat.mode == final_descriptor_stat.mode &&
                           descriptor_stat.uid == final_descriptor_stat.uid &&
                           descriptor_stat.gid == final_descriptor_stat.gid &&
                           descriptor_stat.nlink == final_descriptor_stat.nlink &&
                           final_descriptor_stat.dev == final_path_stat.dev &&
                           final_descriptor_stat.ino == final_path_stat.ino &&
                           final_descriptor_stat.mode == final_path_stat.mode &&
                           final_descriptor_stat.uid == final_path_stat.uid &&
                           final_descriptor_stat.gid == final_path_stat.gid &&
                           final_descriptor_stat.nlink == final_path_stat.nlink
        raise TransactionFailure, "changed overlay durability directory: #{directory}" unless stable_directory
      end
    rescue TransactionFailure
      raise
    rescue SystemCallError, IOError => e
      raise TransactionFailure, "could not fsync overlay directory #{directory}: #{e.message}"
    end

    sig { params(root: Pathname).void }
    def self.fsync_tree!(root)
      root = root.expand_path
      root_stat = root.lstat
      condition_met = root_stat.directory? && root_stat.uid == Process.uid
      unless condition_met
        raise TransactionFailure, "unsafe overlay durability tree: #{root}"
      end

      directories = T.let([], T::Array[[Pathname, Integer, Integer]])
      root.find do |path|
        path_stat = path.lstat
        if path_stat.symlink?
          next
        elsif path_stat.directory?
          if path_stat.uid != Process.uid
            raise TransactionFailure, "unowned overlay durability directory: #{path}"
          end

          directories << [path, path_stat.dev, path_stat.ino]
          next
        elsif !path_stat.file?
          raise TransactionFailure, "unsupported overlay durability entry: #{path}"
        end

        flags = File::RDONLY | File::NOFOLLOW
        File.open(path, flags) do |file|
          descriptor_stat = file.stat
          current_path_stat = path.lstat
          safe_file = descriptor_stat.file? && descriptor_stat.uid == Process.uid &&
                      current_path_stat.file? && current_path_stat.uid == Process.uid &&
                      descriptor_stat.dev == current_path_stat.dev && descriptor_stat.ino == current_path_stat.ino
          raise TransactionFailure, "unsafe overlay durability file: #{path}" unless safe_file

          file.fsync
          final_descriptor_stat = file.stat
          final_path_stat = path.lstat
          stable_file = descriptor_stat.dev == final_descriptor_stat.dev &&
                        descriptor_stat.ino == final_descriptor_stat.ino &&
                        descriptor_stat.mode == final_descriptor_stat.mode &&
                        descriptor_stat.uid == final_descriptor_stat.uid &&
                        descriptor_stat.nlink == final_descriptor_stat.nlink &&
                        descriptor_stat.size == final_descriptor_stat.size &&
                        descriptor_stat.mtime == final_descriptor_stat.mtime &&
                        descriptor_stat.ctime == final_descriptor_stat.ctime &&
                        final_descriptor_stat.dev == final_path_stat.dev &&
                        final_descriptor_stat.ino == final_path_stat.ino &&
                        final_descriptor_stat.mode == final_path_stat.mode &&
                        final_descriptor_stat.uid == final_path_stat.uid &&
                        final_descriptor_stat.nlink == final_path_stat.nlink
          raise TransactionFailure, "changed overlay durability file: #{path}" unless stable_file
        end
      end
      directories.reverse_each do |directory, device, inode|
        fsync_directory!(directory, expected_device: device, expected_inode: inode)
      end
    rescue TransactionFailure
      raise
    rescue SystemCallError, IOError => e
      raise TransactionFailure, "could not fsync overlay tree #{root}: #{e.message}"
    end

    sig { params(path: Pathname, contents: String, mode: Integer).void }
    def self.durable_atomic_write!(path, contents, mode:)
      path = path.expand_path
      if path.symlink? || (path.exist? && !path.file?)
        raise TransactionFailure, "unsafe overlay durability file: #{path}"
      end

      path.atomic_write(contents)
      path.chmod(mode)
      flags = File::RDONLY | File::NOFOLLOW
      File.open(path, flags) do |file|
        descriptor_stat = file.stat
        path_stat = path.lstat
        safe_file = descriptor_stat.file? && descriptor_stat.uid == Process.uid && descriptor_stat.nlink == 1 &&
                    descriptor_stat.size == contents.bytesize && (descriptor_stat.mode & 0777) == mode &&
                    path_stat.file? && path_stat.uid == Process.uid && path_stat.nlink == 1 &&
                    descriptor_stat.dev == path_stat.dev &&
                    descriptor_stat.ino == path_stat.ino
        raise TransactionFailure, "unsafe overlay durability file: #{path}" unless safe_file

        file.fsync
        final_descriptor_stat = file.stat
        final_path_stat = path.lstat
        stable_file = descriptor_stat.dev == final_descriptor_stat.dev &&
                      descriptor_stat.ino == final_descriptor_stat.ino &&
                      descriptor_stat.mode == final_descriptor_stat.mode &&
                      descriptor_stat.uid == final_descriptor_stat.uid &&
                      descriptor_stat.nlink == final_descriptor_stat.nlink &&
                      descriptor_stat.size == final_descriptor_stat.size &&
                      descriptor_stat.mtime == final_descriptor_stat.mtime &&
                      descriptor_stat.ctime == final_descriptor_stat.ctime &&
                      final_descriptor_stat.dev == final_path_stat.dev &&
                      final_descriptor_stat.ino == final_path_stat.ino &&
                      final_descriptor_stat.mode == final_path_stat.mode &&
                      final_descriptor_stat.uid == final_path_stat.uid &&
                      final_descriptor_stat.nlink == final_path_stat.nlink &&
                      final_descriptor_stat.size == final_path_stat.size &&
                      final_descriptor_stat.mtime == final_path_stat.mtime &&
                      final_descriptor_stat.ctime == final_path_stat.ctime
        raise TransactionFailure, "changed overlay durability file: #{path}" unless stable_file
      end
      fsync_directory!(path.parent)
    rescue TransactionFailure
      raise
    rescue SystemCallError, IOError => e
      raise TransactionFailure, "could not durably write overlay file #{path}: #{e.message}"
    end

    sig { params(path: Pathname).void }
    def self.durable_unlink!(path)
      path = path.expand_path
      flags = File::RDONLY | File::NOFOLLOW
      File.open(path, flags) do |file|
        descriptor_stat = file.stat
        path_stat = path.lstat
        safe_file = descriptor_stat.file? && descriptor_stat.uid == Process.uid && descriptor_stat.nlink == 1 &&
                    descriptor_stat.mode.nobits?(0022) && path_stat.file? && path_stat.uid == Process.uid &&
                    path_stat.nlink == 1 && descriptor_stat.dev == path_stat.dev &&
                    descriptor_stat.ino == path_stat.ino
        raise TransactionFailure, "unsafe overlay durability file: #{path}" unless safe_file

        path.unlink
        fsync_directory!(path.parent)
        removed = file.stat.nlink.zero? && !path.exist? && !path.symlink?
        unless removed
          raise TransactionFailure, "changed overlay durability file while removing: #{path}"
        end
      end
    rescue TransactionFailure
      raise
    rescue SystemCallError, IOError => e
      raise TransactionFailure, "could not durably remove overlay file #{path}: #{e.message}"
    end

    sig {
      params(
        path:            Pathname,
        expected_device: T.nilable(Integer),
        expected_inode:  T.nilable(Integer),
      ).void
    }
    def self.remove_tree_durable!(path, expected_device: nil, expected_inode: nil)
      path = path.expand_path
      path_present = path.exist? || path.symlink?
      return unless path_present

      parent = path.parent
      parent_stat = parent.lstat
      path_stat = path.lstat
      expected_identity = if expected_device.nil? && expected_inode.nil?
        true
      elsif expected_device && expected_inode
        path_stat.dev == expected_device && path_stat.ino == expected_inode
      else
        false
      end
      safe_path =
        parent_stat.directory? &&
        !parent.symlink? &&
        parent_stat.uid == Process.uid &&
        path_stat.directory? &&
        !path.symlink? &&
        path_stat.uid == Process.uid &&
        expected_identity
      raise TransactionFailure, "unsafe overlay cleanup path: #{path}" unless safe_path

      tombstone = T.let(nil, T.nilable(Pathname))
      32.times do
        candidate = parent/".cleanup-#{path.basename}-#{SecureRandom.hex(8)}"
        next if candidate.exist? || candidate.symlink?

        begin
          File.rename(path, candidate)
        rescue Errno::EEXIST
          next
        end
        tombstone = candidate
        break
      end
      detached = !tombstone.nil? && !path.exist? && !path.symlink?
      raise TransactionFailure, "could not detach overlay cleanup path: #{path}" unless detached

      detached_path = tombstone
      fsync_directory!(parent, expected_device: parent_stat.dev, expected_inode: parent_stat.ino)
      detached_stat = detached_path.lstat
      stable_detach =
        detached_stat.directory? &&
        detached_stat.uid == path_stat.uid &&
        detached_stat.dev == path_stat.dev &&
        detached_stat.ino == path_stat.ino
      raise TransactionFailure, "overlay cleanup path changed while detaching: #{path}" unless stable_detach

      FileUtils.rm_rf(detached_path)
      removed = !detached_path.exist? && !detached_path.symlink?
      raise TransactionFailure, "could not remove detached overlay cleanup path: #{detached_path}" unless removed

      fsync_directory!(parent, expected_device: parent_stat.dev, expected_inode: parent_stat.ino)
    rescue TransactionFailure
      raise
    rescue SystemCallError, IOError => e
      raise TransactionFailure, "could not durably remove overlay tree #{path}: #{e.message}"
    end

    sig { params(path: T.any(Pathname, String)).returns(T::Boolean) }
    def self.inherited_path?(path)
      condition_met = active? && base_cellar.directory?
      return false unless condition_met

      path_under?(canonical_path(Pathname(path)), canonical_path(base_cellar))
    end

    sig { params(path: Pathname).returns(T::Boolean) }
    def self.valid_keg_path?(path)
      return true if @install_transactions.values.any? do |transaction|
        path.parent.expand_path == T.cast(transaction, FormulaTransaction).staging_rack.expand_path
      end
      if (staging_rack = install_rack(path.parent.basename.to_s))
        return path.parent.expand_path == staging_rack.expand_path
      end

      cellar = canonical_path(path.parent.parent)
      candidate_cellars = [HOMEBREW_CELLAR]
      candidate_cellars << base_cellar if active?

      candidate_cellars.any? do |candidate|
        candidate.directory? && canonical_path(candidate) == cellar
      end
    end

    sig { params(rack: Pathname).returns(T::Boolean) }
    def self.inherited_rack?(rack)
      condition_met = active? && rack.directory?
      return false unless condition_met
      return inherited_path?(rack) if rack.symlink?

      children = rack.children.reject { |child| child.basename.to_s.start_with?(".") }
      children.any? && children.all? { |child| inherited_keg?(child) }
    end

    sig { params(keg_path: T.any(Pathname, String)).returns(T::Boolean) }
    def self.inherited_keg?(keg_path)
      active? && inherited_path?(keg_path)
    end

    sig { params(formula_name: String, version: String).returns(T::Boolean) }
    def self.inherited_install_target?(formula_name, version)
      return false unless active?
      return false unless valid_formula_name?(formula_name)
      return false unless valid_version_name?(version)

      rack = HOMEBREW_CELLAR/formula_name
      keg = rack/version
      return false unless rack.directory?
      return false if rack.symlink?
      return false unless keg.symlink?

      inherited_keg?(keg)
    end

    sig { params(formula_name: String, version: String).void }
    def self.validate_local_install_target!(formula_name, version)
      return unless inherited_install_target?(formula_name, version)

      raise TransactionFailure, <<~EOS
        #{HOMEBREW_CELLAR/formula_name/version} is an inherited administrator version inside a local version-union rack.
        Refusing to install through that symlink. Remove the local override for #{formula_name}, then retry the install.
      EOS
    end

    sig { params(formula_name: String, version: String).returns(T::Boolean) }
    def self.local_keg_realization?(formula_name, version)
      condition_met = active? && valid_formula_name?(formula_name) && valid_version_name?(version)
      return false unless condition_met

      rack = HOMEBREW_CELLAR/formula_name
      keg = rack/version
      rack.directory? && !rack.symlink? && keg.directory? && !keg.symlink?
    end

    sig { params(formula_name: String).returns(T::Boolean) }
    def self.local_realizations?(formula_name)
      rack = HOMEBREW_CELLAR/formula_name
      condition_met = rack.directory? && !rack.symlink?
      return false unless condition_met

      rack.children.any? do |child|
        !child.symlink? && child.directory? && !child.basename.to_s.start_with?(".")
      end
    end

    sig { params(formula_name: String).returns(T.nilable(Pathname)) }
    def self.base_rack(formula_name)
      condition_met = active? && valid_formula_name?(formula_name)
      return unless condition_met

      rack = base_cellar/formula_name
      condition_met = rack.directory? && !rack.symlink?
      return unless condition_met
      return unless rack.children.any? do |child|
        child.directory? && !child.symlink? && !child.basename.to_s.start_with?(".")
      end

      rack
    end

    sig { params(formula_name: String).returns(T::Boolean) }
    def self.base_formula_available?(formula_name)
      !base_rack(formula_name).nil?
    end

    sig { params(formula: T.untyped).returns(T::Boolean) }
    def self.inherited_only_formula?(formula)
      return false unless active?

      kegs = formula.installed_kegs
      kegs.any? && kegs.all? { |keg| inherited_keg?(keg.to_path) }
    end

    sig { params(formula_name: String).returns(T::Boolean) }
    def self.inherited_migration_target?(formula_name)
      base_formula_available?(formula_name)
    end

    sig { params(formula: T.untyped).returns(T::Boolean) }
    def self.transaction_required?(formula)
      condition_met = active? && valid_formula_name?(formula.name)
      return false unless condition_met

      base_rack = base_cellar/formula.name
      base_rack.directory? && !base_rack.symlink? && !local_realizations?(formula.name)
    end

    sig {
      params(formula: T.untyped, base_generation: String)
        .returns(T.nilable(FormulaTransaction))
    }
    def self.begin_formula_transaction(formula, base_generation:)
      return unless transaction_required?(formula)

      FormulaTransaction.new(formula, base_generation:).start!
    end

    sig { params(generation: String).void }
    def self.validate_base_generation!(generation)
      return if generation.match?(BASE_GENERATION_PATTERN)

      raise TransactionFailure, "invalid administrator base generation: #{generation.inspect}"
    end

    # Hold a shared descriptor-bound lease on the administrator mutation lock
    # while a developer install consumes inherited files. Patched administrator
    # mutations take the same lock exclusively, so the lower package layer
    # cannot change beneath a running build.
    sig { returns(File) }
    def self.acquire_base_mutation_lease
      raise TransactionFailure, "administrator mutation lease is unavailable outside an active overlay" unless active?

      prefix = base_prefix.expand_path
      lock_path = prefix/"var/homebrew/locks/overlay-mutation.lock"
      prefix_stat = prefix.lstat
      safe_prefix = prefix_stat.directory? && !prefix.symlink?
      raise TransactionFailure, "unsafe administrator Homebrew prefix: #{prefix}" unless safe_prefix

      flags = File::RDONLY | File::NOFOLLOW
      lease = open_retained_file(lock_path, flags)
      descriptor_stat = lease.stat
      path_stat = lock_path.lstat
      safe_lock = descriptor_stat.file? && descriptor_stat.uid == prefix_stat.uid && descriptor_stat.nlink == 1 &&
                  descriptor_stat.mode.nobits?(0022) && path_stat.file? && path_stat.uid == prefix_stat.uid &&
                  path_stat.nlink == 1 && descriptor_stat.dev == path_stat.dev && descriptor_stat.ino == path_stat.ino
      raise TransactionFailure, "unsafe administrator Homebrew mutation lock: #{lock_path}" unless safe_lock

      unless lease.flock(File::LOCK_SH | File::LOCK_NB)
        raise TransactionFailure,
              "the administrator Homebrew prefix is being mutated; retry after the administrator update finishes"
      end

      final_descriptor_stat = lease.stat
      final_path_stat = lock_path.lstat
      stable_lock = descriptor_stat.dev == final_descriptor_stat.dev &&
                    descriptor_stat.ino == final_descriptor_stat.ino &&
                    descriptor_stat.mode == final_descriptor_stat.mode &&
                    descriptor_stat.uid == final_descriptor_stat.uid &&
                    descriptor_stat.nlink == final_descriptor_stat.nlink &&
                    final_descriptor_stat.dev == final_path_stat.dev &&
                    final_descriptor_stat.ino == final_path_stat.ino &&
                    final_descriptor_stat.mode == final_path_stat.mode &&
                    final_descriptor_stat.uid == final_path_stat.uid &&
                    final_descriptor_stat.nlink == final_path_stat.nlink
      unless stable_lock
        raise TransactionFailure,
              "administrator Homebrew mutation lock changed while acquiring it: #{lock_path}"
      end

      lease
    rescue TransactionFailure
      lease&.close unless lease&.closed?
      raise
    rescue SystemCallError, IOError => e
      lease&.close unless lease&.closed?
      raise TransactionFailure, "could not acquire administrator Homebrew mutation lease: #{e.message}"
    end

    sig { params(lease: T.nilable(File)).void }
    def self.release_base_mutation_lease(lease)
      return if lease.nil? || lease.closed?

      lease.flock(File::LOCK_UN)
      lease.close
    rescue SystemCallError, IOError => e
      raise TransactionFailure, "could not release administrator Homebrew mutation lease: #{e.message}"
    end

    sig { returns(String) }
    def self.current_base_generation
      unless active?
        raise TransactionFailure,
              "administrator base generation is unavailable outside an active overlay"
      end

      script = HOMEBREW_LIBRARY_PATH/"utils/overlay.sh"
      generation = Utils.safe_popen_read(
        { "HOMEBREW_OVERLAY_BASE_PREFIX" => base_prefix.to_s },
        "/bin/bash", script.to_s, "--base-generation", err: :close
      ).strip
      validate_base_generation!(generation)
      generation
    rescue ErrorDuringExecution, SystemCallError => e
      raise TransactionFailure, "could not determine administrator base generation: #{e}"
    end

    sig { params(expected: String).void }
    def self.verify_base_generation!(expected)
      validate_base_generation!(expected)
      actual = current_base_generation
      raise BaseGenerationChangedError.new(expected, actual) if actual != expected
    end

    sig { params(keg_path: T.any(Pathname, String), generation: String).void }
    def self.record_base_generation!(keg_path, generation)
      validate_base_generation!(generation)
      path = Pathname(keg_path).expand_path
      rack = path.parent
      local_keg = active? && path.directory? && !path.symlink? &&
                  rack.directory? && !rack.symlink? && rack.parent.expand_path == HOMEBREW_CELLAR.expand_path &&
                  valid_formula_name?(rack.basename.to_s) && valid_version_name?(path.basename.to_s) &&
                  path.stat.uid == Process.uid
      unless local_keg
        raise TransactionFailure, "refusing to record a base generation outside a local keg: #{path}"
      end

      marker = path/BASE_GENERATION_MARKER
      if marker.symlink? || (marker.exist? && !marker.file?)
        raise TransactionFailure, "unsafe administrator base-generation marker: #{marker}"
      end

      durable_atomic_write!(marker, "#{generation}\n", mode: 0600)
    end

    sig { returns(T::Array[Pathname]) }
    def self.base_generation_drift
      return [] unless active?

      current = current_base_generation
      drift = T.let([], T::Array[Pathname])
      HOMEBREW_CELLAR.children.sort.each do |rack|
        valid_rack = rack.directory? && !rack.symlink? && valid_formula_name?(rack.basename.to_s)
        next unless valid_rack

        rack.children.sort.each do |keg|
          valid_keg = keg.directory? && !keg.symlink? && valid_version_name?(keg.basename.to_s)
          next unless valid_keg

          marker = keg/BASE_GENERATION_MARKER
          recorded = begin
            read_owned_file(
              marker,
              description: "administrator base-generation marker",
              max_bytes:   65,
            )
          rescue TransactionFailure
            nil
          end
          drift << keg if recorded != "#{current}\n"
        end
      end
      drift
    end

    sig { params(transaction: FormulaTransaction).void }
    def self.register_transaction(transaction)
      existing = @install_transactions[transaction.formula_name]
      if existing && existing != transaction
        raise "another overlay install transaction is active for #{transaction.formula_name}"
      end

      @install_transactions[transaction.formula_name] = transaction
    end

    sig { params(formula_name: String, transaction: FormulaTransaction).void }
    def self.unregister_transaction(formula_name, transaction)
      @install_transactions.delete(formula_name) if @install_transactions[formula_name] == transaction
    end

    sig { params(backup: ReinstallBackup).void }
    def self.register_reinstall_backup(backup)
      key = "#{backup.formula_name}\0#{backup.version}"
      existing = @reinstall_backups[key]
      if existing && existing != backup
        raise TransactionFailure, "another overlay reinstall backup is active for #{backup.formula_name}"
      end

      @reinstall_backups[key] = backup
    end

    sig { params(backup: ReinstallBackup).void }
    def self.unregister_reinstall_backup(backup)
      key = "#{backup.formula_name}\0#{backup.version}"
      @reinstall_backups.delete(key) if @reinstall_backups[key] == backup
    end

    sig { params(formula_name: String, version: String, keg_path: Pathname).void }
    def self.mark_reinstall_committed!(formula_name, version, keg_path)
      key = "#{formula_name}\0#{version}"
      backup = T.cast(@reinstall_backups[key], T.nilable(ReinstallBackup))
      backup&.mark_committed!(keg_path)
    end

    sig { params(formula_name: String).returns(T.nilable(Pathname)) }
    def self.install_rack(formula_name)
      transaction = @install_transactions[formula_name]
      return transaction.staging_rack if transaction

      transaction_id = ENV.fetch("HOMEBREW_OVERLAY_INSTALL_TRANSACTION_ID", nil)
      return if transaction_id.blank?

      valid_transaction_id =
        active? &&
        valid_formula_name?(formula_name) &&
        transaction_id.match?(/\A[1-9][0-9]*-[0-9a-f]{24}\z/)
      unless valid_transaction_id
        raise TransactionFailure, "invalid overlay build transaction"
      end

      transaction_dir = transactions_dir/transaction_id
      recorded_formula = read_owned_file(
        transaction_dir/"formula",
        description: "overlay transaction formula",
        max_bytes:   256,
      )
      return if recorded_formula != "#{formula_name}\n"

      state = read_owned_file(
        transaction_dir/"state",
        description: "overlay transaction state",
        max_bytes:   32,
      )
      if state != "staging\n"
        raise TransactionFailure, "overlay build transaction does not match #{formula_name}"
      end

      staging_root = HOMEBREW_CELLAR/".homebrew-overlay-staging"/transaction_id
      staging_rack = staging_root/formula_name
      [staging_root.parent, staging_root, staging_rack].each do |directory|
        safe_staging_directory =
          directory.directory? &&
          !directory.symlink? &&
          directory.stat.uid == Process.uid &&
          directory.writable?
        unless safe_staging_directory
          raise TransactionFailure, "unsafe overlay build staging directory: #{directory}"
        end
      end

      staging_rack
    end

    sig { params(formula_name: String).void }
    def self.ensure_inherited_rack!(formula_name)
      base_rack = base_cellar/formula_name
      condition_met = base_rack.directory? && !base_rack.symlink?
      unless condition_met
        raise TransactionFailure, "administrator formula rack is unavailable: #{base_rack}"
      end

      rack = HOMEBREW_CELLAR/formula_name
      if !rack.exist? && !rack.symlink?
        File.symlink(base_rack, rack)
      elsif rack.symlink?
        condition_met = inherited_path?(rack) && canonical_path(rack) == canonical_path(base_rack)
        unless condition_met
          raise TransactionFailure, "refusing to replace non-inherited formula rack: #{rack}"
        end
      elsif !rack.directory?
        raise TransactionFailure, "formula rack is not a directory: #{rack}"
      elsif local_realizations?(formula_name)
        raise TransactionFailure, "formula rack already contains a local realization: #{rack}"
      end
    end

    sig { params(formula_name: String).returns(T::Boolean) }
    def self.restore_inherited_rack!(formula_name)
      valid_formula = active? && valid_formula_name?(formula_name)
      return false unless valid_formula

      rack = HOMEBREW_CELLAR/formula_name
      inherited_rack = rack.directory? && !rack.symlink? && base_formula_available?(formula_name)
      return false unless inherited_rack
      return false if local_realizations?(formula_name)

      rack.children.each do |child|
        inherited_child = child.symlink? && inherited_keg?(child)
        raise TransactionFailure, "refusing to collapse non-inherited formula rack: #{rack}" unless inherited_child

        child.unlink
      end
      rack.rmdir
      File.symlink(base_cellar/formula_name, rack)
      fsync_directory!(rack.parent)
      true
    rescue Errno::EEXIST, Errno::ENOTEMPTY => e
      raise TransactionFailure, "could not restore inherited formula rack #{rack}: #{e.message}"
    end

    # Validate GNU mv's exchange support on the actual user Cellar filesystem
    # before a bottle or source build is started. A successful round trip proves
    # both the userspace option and renameat2(RENAME_EXCHANGE) support.
    sig { void }
    def self.ensure_atomic_exchange_supported!
      return unless active?
      return if @atomic_exchange_supported

      owns_mutation = !mutation_active?
      parent = T.let(HOMEBREW_CELLAR/".homebrew-overlay-staging", Pathname)
      probe = T.let(nil, T.nilable(Pathname))
      begin
        begin_mutation! if owns_mutation
        ensure_owned_directory!(parent)
        probe = parent/".exchange-probe-#{Process.pid}-#{SecureRandom.hex(8)}"
        left = probe/"left"
        right = probe/"right"
        ensure_owned_directory!(left)
        ensure_owned_directory!(right)
        left.chmod 0700
        right.chmod 0700
        (left/"identity").write("left\n")
        (right/"identity").write("right\n")
        left_identity = [left.stat.dev, left.stat.ino]
        right_identity = [right.stat.dev, right.stat.ino]
        fsync_tree!(probe)

        atomic_exchange!(left, right)
        swapped_exactly = [right.stat.dev, right.stat.ino] == left_identity &&
                          [left.stat.dev, left.stat.ino] == right_identity &&
                          (left/"identity").read == "right\n" && (right/"identity").read == "left\n"
        unless swapped_exactly
          raise TransactionFailure, "atomic overlay exchange probe did not swap Cellar directories exactly"
        end

        atomic_exchange!(left, right)
        restored_exactly = [left.stat.dev, left.stat.ino] == left_identity &&
                           [right.stat.dev, right.stat.ino] == right_identity &&
                           (left/"identity").read == "left\n" && (right/"identity").read == "right\n"
        unless restored_exactly
          raise TransactionFailure, "atomic overlay exchange probe did not restore Cellar directories exactly"
        end

        @atomic_exchange_supported = true
      ensure
        if probe && (probe.exist? || probe.symlink?)
          safe_probe = probe.directory? && !probe.symlink? && probe.stat.uid == Process.uid
          raise TransactionFailure, "unsafe atomic overlay exchange probe: #{probe}" unless safe_probe

          probe_stat = probe.lstat
          remove_tree_durable!(
            probe,
            expected_device: probe_stat.dev,
            expected_inode:  probe_stat.ino,
          )
        end
        sync!(mutation: true) if owns_mutation && mutation_active?
      end
    end

    # Atomically exchange two paths on Linux. Both paths are required to live
    # in the active Cellar so the operation is same-filesystem and cannot be
    # redirected through an arbitrary user path.
    sig { params(left: Pathname, right: Pathname).void }
    def self.atomic_exchange!(left, right)
      cellar = HOMEBREW_CELLAR.expand_path
      [left, right].each do |path|
        condition_met = path_under?(path.expand_path, cellar) && (path.exist? || path.symlink?)
        unless condition_met
          raise TransactionFailure, "unsafe overlay exchange path: #{path}"
        end
      end

      mv = %w[/bin/mv /usr/bin/mv].find { |candidate| File.executable?(candidate) }
      raise TransactionFailure, "atomic overlay publication requires GNU mv with --exchange" unless mv

      begin
        Homebrew.safe_system mv, "--exchange", "--no-target-directory", left.to_s, right.to_s
      rescue ErrorDuringExecution, SystemCallError => e
        raise TransactionFailure, "atomic overlay rack exchange failed: #{e.message}"
      end

      [left.parent, right.parent].uniq.each { |parent| fsync_directory!(parent) }
    end

    # Remove a newly created, not-yet-committed local keg after an overlay
    # install fails. The exact rack and version must both be real, user-owned
    # paths in the active Cellar; inherited symlinks and pre-existing kegs are
    # never accepted by this helper.
    sig { params(formula_name: String, version: String).returns(T::Boolean) }
    def self.discard_local_keg!(formula_name, version)
      return false unless local_keg_realization?(formula_name, version)

      rack = HOMEBREW_CELLAR/formula_name
      keg = rack/version
      if rack.stat.uid != Process.uid || keg.stat.uid != Process.uid
        raise TransactionFailure, "refusing to discard a local keg not owned by the current user: #{keg}"
      end

      begin_mutation! unless mutation_active?
      remove_links_to!(keg)
      keg_stat = keg.lstat
      remove_tree_durable!(keg, expected_device: keg_stat.dev, expected_inode: keg_stat.ino)

      rack.rmdir_if_possible
      clear_caches!
      sync!(mutation: true)
      true
    end

    # Remove only symlinks in native Homebrew link roots that resolve into the
    # supplied transaction-owned keg. This is intentionally conservative: no
    # regular file or unrelated user symlink is touched.
    sig { params(version_path: Pathname).void }
    def self.remove_links_to!(version_path)
      return unless active?

      %w[bin sbin include lib share Frameworks opt var/homebrew/linked].each do |relative_root|
        root = HOMEBREW_PREFIX/relative_root
        condition_met = root.directory? && !root.symlink?
        next unless condition_met

        root.find do |path|
          next unless path.symlink?

          resolved = canonical_path(path)
          path.unlink if path_under?(resolved, version_path)
        end
      end
    end

    # Map a real base keg path back into the active prefix's logical Cellar.
    # Keg.for uses this only when the path was reached through the user prefix.
    sig { params(real_keg_path: Pathname).returns(Pathname) }
    def self.logical_keg_path(real_keg_path)
      return real_keg_path unless active?

      real_keg_path = canonical_path(real_keg_path)
      return real_keg_path if real_keg_path.parent.parent != canonical_path(base_cellar)

      HOMEBREW_CELLAR/real_keg_path.parent.basename/real_keg_path.basename
    end

    sig { params(path: Pathname).returns(T::Boolean) }
    def self.active_prefix_path?(path)
      active? && path_under?(path.expand_path, HOMEBREW_PREFIX.expand_path)
    end

    sig { returns(Pathname) }
    def self.link_state_file
      HOMEBREW_PREFIX/"var/homebrew/overlay/view.state"
    end

    sig { params(relative: String).returns(T.nilable(String)) }
    def self.expected_link_target(relative)
      components = relative.split("/", -1)
      formula = if (components.length == 2 && %w[Cellar opt].include?(components.first)) ||
                   (components.length == 3 && components.first == "Cellar")
        components[1]
      elsif components.length == 4 && components.first(3) == %w[var homebrew linked]
        components[3]
      end
      return if formula.nil?
      return unless valid_formula_name?(formula)

      version = (components.length == 3) ? components[2] : nil
      valid_version = version.nil? || valid_version_name?(version)
      return unless valid_version

      (base_prefix/relative).to_s
    end
    private_class_method :expected_link_target

    sig { returns(T::Hash[String, String]) }
    def self.link_state_entries
      cached_entries = @link_state_entries
      return cached_entries if cached_entries

      state = link_state_file
      contents = read_owned_file(
        state,
        description: "overlay view state",
        max_bytes:   MAX_MANAGED_STATE_BYTES,
      )
      entries = T.let({}, T::Hash[String, String])
      if contents.present?
        unless contents.end_with?("\0")
          raise TransactionFailure, "invalid overlay view state: #{state}"
        end

        fields = contents.split("\0", -1)
        fields.pop
        valid_fields = fields.length.even? && fields.none?(&:empty?)
        raise TransactionFailure, "invalid overlay view state: #{state}" unless valid_fields

        fields.each_slice(2) do |relative, target|
          relative = T.must(relative)
          target = T.must(target)
          expected = expected_link_target(relative)
          if expected.nil? || target != expected || entries.key?(relative)
            raise TransactionFailure, "invalid overlay view state: #{state}"
          end

          entries[relative] = target
        end
      end
      @link_state_entries = entries
    end
    private_class_method :link_state_entries

    sig { params(path: Pathname).returns(T::Boolean) }
    def self.inherited_prefix_link?(path)
      condition_met = active? && path.symlink? && active_prefix_path?(path)
      return false unless condition_met

      relative = path.relative_path_from(HOMEBREW_PREFIX).to_s
      expected_target = link_state_entries[relative]
      !expected_target.nil? && path.readlink.to_s == expected_target
    rescue ArgumentError
      false
    end

    # Resolve only the second hop of an overlay-managed record. Ordinary user
    # symlinks keep native Homebrew's one-hop behavior and are never trusted as
    # authorization to traverse an arbitrary chain.
    sig { params(path: Pathname).returns(T.nilable(Pathname)) }
    def self.keg_record_target(path)
      return unless path.symlink?

      return unless path.directory?

      return path.resolved_path unless inherited_prefix_link?(path)

      resolved = path.realpath
      cellar = canonical_path(base_cellar)
      return unless path_under?(resolved, cellar)

      components = resolved.relative_path_from(cellar).each_filename.to_a
      return unless components.length.between?(1, 2)
      return unless valid_formula_name?(T.must(components.first))
      return if components.length == 2 && !valid_version_name?(T.must(components.last))

      resolved
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, ArgumentError
      nil
    end

    sig { params(path: Pathname).returns(T::Boolean) }
    def self.remove_inherited_prefix_link!(path)
      return false unless inherited_prefix_link?(path)

      path.unlink
      true
    end

    sig { returns(T::Boolean) }
    def self.mutation_active? = !@mutation_lock.nil?

    # Serialize native package mutations and publish a durable dirty marker
    # before the first filesystem change. The advisory lock remains held by the
    # Ruby process until the generation is bumped or a mutation sync completes.
    # A concurrent brew invocation therefore refuses to bless a transient
    # Cellar, while a crashed process releases the lock but leaves the marker for
    # structural recovery on the next invocation.
    sig { void }
    def self.begin_mutation!
      return unless Homebrew::EnvConfig.overlay?

      return if @mutation_lock

      lock_path = HOMEBREW_PREFIX/"var/homebrew/locks/overlay-mutation.lock"
      lock_dir = lock_path.parent
      ensure_owned_directory!(lock_dir)
      if lock_path.symlink? || (lock_path.exist? && !lock_path.file?)
        raise TransactionFailure, "unsafe overlay mutation lock: #{lock_path}"
      end

      flags = File::RDWR | File::CREAT | File::NOFOLLOW
      lock = open_retained_file(lock_path, flags, mode: 0640)
      lock_stat = lock.stat
      safe_lock = lock_stat.file? && lock_stat.uid == Process.uid && lock_stat.nlink == 1
      unless safe_lock
        lock.close
        raise TransactionFailure, "unsafe overlay mutation lock: #{lock_path}"
      end
      lock.chmod 0640
      lock.flock(File::LOCK_EX)
      @mutation_lock = lock

      script = HOMEBREW_LIBRARY_PATH/"utils/overlay.sh"
      environment, options = mutation_process_context
      Homebrew.safe_system environment, "/bin/bash", script,
                           "--mark-generation-dirty", HOMEBREW_PREFIX.to_s, **options
    # Cleanup must also restore durable state for Interrupt and SystemExit.
    rescue Exception # rubocop:disable Lint/RescueException
      release_mutation_lock!
      raise
    end

    # Advance the native prefix's explicit package generation after a
    # completed mutation. Native helpers reuse an already-active outer scope;
    # the owner writes the generation, removes the dirty marker, and releases
    # the global mutation lock.
    sig { void }
    def self.bump_generation!
      return unless Homebrew::EnvConfig.overlay?

      begin_mutation! unless mutation_active?

      script = HOMEBREW_LIBRARY_PATH/"utils/overlay.sh"
      environment, options = mutation_process_context(finalize: true)
      Homebrew.safe_system environment, "/bin/bash", script,
                           "--bump-generation", HOMEBREW_PREFIX.to_s, **options
      release_mutation_lock!
    # Cleanup must also restore durable state for Interrupt and SystemExit.
    rescue Exception # rubocop:disable Lint/RescueException
      release_mutation_lock!
      raise
    end

    sig { params(mutation: T::Boolean, owner_transaction: T.nilable(FormulaTransaction)).void }
    def self.sync!(mutation: false, owner_transaction: nil)
      return unless active?

      begin_mutation! if mutation && !mutation_active?

      script = HOMEBREW_LIBRARY_PATH/"utils/overlay.sh"
      environment, options = mutation_process_context(finalize: mutation, owner_transaction:)
      Homebrew.safe_system environment, "/bin/bash", script, "--sync", **options
      release_mutation_lock! if mutation
      @link_state_entries = nil
    # Cleanup must also restore durable state for Interrupt and SystemExit.
    rescue Exception # rubocop:disable Lint/RescueException
      release_mutation_lock! if mutation
      raise
    end

    sig {
      params(
        finalize:          T::Boolean,
        owner_transaction: T.nilable(FormulaTransaction),
      ).returns([T::Hash[String, T.nilable(String)], T::Hash[T.untyped, T.untyped]])
    }
    def self.mutation_process_context(finalize: false, owner_transaction: nil)
      environment = T.let({}, T::Hash[String, T.nilable(String)])
      options = T.let({}, T::Hash[T.untyped, T.untyped])
      mutation_lock = @mutation_lock
      if mutation_lock
        raise TransactionFailure, "overlay mutation lock is closed" if mutation_lock.closed?

        environment["HOMEBREW_OVERLAY_MUTATION_LOCK_FD"] = MUTATION_LOCK_DESCRIPTOR.to_s
        options[MUTATION_LOCK_DESCRIPTOR] = mutation_lock
      end
      environment["HOMEBREW_OVERLAY_FINALIZE_MUTATION"] = "1" if finalize

      if owner_transaction
        unless mutation_lock
          raise TransactionFailure, "overlay transaction synchronization requires the mutation lock"
        end

        environment["HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID"] = owner_transaction.id
        environment["HOMEBREW_OVERLAY_OWNER_TRANSACTION_LOCK_FD"] = TRANSACTION_LOCK_DESCRIPTOR.to_s
        options[TRANSACTION_LOCK_DESCRIPTOR] = owner_transaction.owner_lock
      end

      [environment, options]
    end
    private_class_method :mutation_process_context

    sig { void }
    def self.release_mutation_lock!
      lock = @mutation_lock
      if lock
        lock.flock(File::LOCK_UN) unless lock.closed?
        lock.close unless lock.closed?
      end
      @mutation_lock = nil
    end
    private_class_method :release_mutation_lock!

    sig { void }
    def self.clear_caches!
      T.unsafe(::Formula).clear_cache if defined?(::Formula)
      T.unsafe(::Keg).clear_cache if defined?(::Keg)
      @link_state_entries = nil
    end
  end
end
