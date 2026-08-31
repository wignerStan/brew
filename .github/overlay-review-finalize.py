from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old!r}")
    p.write_text(text.replace(old, new, 1))


replace_once(
    "Library/Homebrew/overlay.rb",
    '''        Overlay.durable_atomic_write!(@metadata_state, "backed-up\\n", mode: 0600)
        Overlay.clear_caches!
        self
      rescue Exception # rubocop:disable Lint/RescueException
''',
    '''        Overlay.durable_atomic_write!(@metadata_state, "backed-up\\n", mode: 0600)
        Overlay.clear_caches!
        self
      # Rescue Exception intentionally so recovery runs before non-StandardError interrupts are re-raised.
      rescue Exception # rubocop:disable Lint/RescueException
''',
)

replace_once(
    "Library/Homebrew/overlay.rb",
    "      return false unless active? && valid_formula_name?(formula_name)\n",
    "      valid_formula = active? && valid_formula_name?(formula_name)\n"
    "      return false unless valid_formula\n",
)
replace_once(
    "Library/Homebrew/overlay.rb",
    "      return false unless rack.directory? && !rack.symlink? && base_formula_available?(formula_name)\n",
    "      inherited_rack = rack.directory? && !rack.symlink? && base_formula_available?(formula_name)\n"
    "      return false unless inherited_rack\n",
)
replace_once(
    "Library/Homebrew/overlay.rb",
    '''        unless child.symlink? && inherited_keg?(child)
          raise TransactionFailure, "refusing to collapse non-inherited formula rack: #{rack}"
        end
''',
    '''        inherited_child = child.symlink? && inherited_keg?(child)
        raise TransactionFailure, "refusing to collapse non-inherited formula rack: #{rack}" unless inherited_child
''',
)
replace_once(
    "Library/Homebrew/overlay.rb",
    "      return unless path.symlink?\n"
    "      return unless path.directory?\n\n",
    "      return unless path.symlink?\n\n"
    "      return unless path.directory?\n\n",
)
replace_once(
    "Library/Homebrew/overlay.rb",
    '''          if expected.nil? || target != expected || entries.key?(relative)
            raise TransactionFailure, "invalid overlay view state: #{state}"
          end
          entries[relative] = target
''',
    '''          if expected.nil? || target != expected || entries.key?(relative)
            raise TransactionFailure, "invalid overlay view state: #{state}"
          end

          entries[relative] = target
''',
)

spec_path = Path("Library/Homebrew/test/overlay_spec.rb")
spec = spec_path.read_text()
example = '  it "rejects a transaction marker path replaced after opening" do\n'
start = spec.find(example)
if start < 0:
    raise SystemExit("marker replacement example not found")
old_line = "    marker&.unlink if marker&.exist? || marker&.symlink?\n"
pos = spec.find(old_line, start)
if pos < 0:
    raise SystemExit("marker cleanup line not found inside replacement example")
next_example = spec.find('\n  it "', start + len(example))
if next_example >= 0 and pos >= next_example:
    raise SystemExit("marker cleanup match escaped replacement example")
spec = spec[:pos] + "    marker.unlink if marker&.exist? || marker&.symlink?\n" + spec[pos + len(old_line):]
spec_path.write_text(spec)
