#!/usr/bin/env python3
from pathlib import Path

path = Path(".github/scripts/build_overlay_pr_cleanup.py")
source = path.read_text(encoding="utf-8")
anchor = 'core_path.write_text(core, encoding="utf-8")\n'
insertion = r'''reader_start = core.index(
    "    sig {\n"
    "      params(\n"
    "        path:        Pathname,\n"
    "        description: String,\n"
    "        max_bytes:   Integer,\n"
    "      ).returns(T.nilable(String))\n"
    "    }\n"
    "    def self.read_owned_file(path, description:, max_bytes:)\n"
)
reader_end = core.index(
    "\n    sig { params(path: Pathname).returns(Pathname) }",
    reader_start,
)
descriptor_reader = """    sig {
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
"""
core = core[:reader_start] + descriptor_reader + core[reader_end:]

'''
if source.count(anchor) != 1:
    raise SystemExit("core writer anchor changed")
path.write_text(source.replace(anchor, insertion + anchor), encoding="utf-8")
