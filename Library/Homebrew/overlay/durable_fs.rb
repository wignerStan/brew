# typed: strict
# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Homebrew
  module Overlay
    # Crash-consistent creation, publication, synchronization, and cleanup primitives.
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
  end
end
