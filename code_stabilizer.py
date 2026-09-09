#!/usr/bin/env python3
"""
code_stabilizer.py

Command-line tool that converts text files in-place from an ANSI codepage
encoding to UTF-8 with a byte-order mark (BOM).

Argument syntax:
  code_stabilizer.py [-s] [-w] [-f] [-a:<codepage>] <file|pattern|@listfile> [...]

  -s              Recurse into subdirectories when expanding wildcard patterns.
  -w              Add the L prefix to narrow string literals ("...") that
                  contain characters outside ASCII, turning "ahoj" into
                  L"ahoj" only where the wide prefix is actually needed.
                  Literals wrapped in the TEXT() macro are left alone,
                  because TEXT() adds the L prefix itself. When at least
                  one literal on a line needs the L prefix, the remaining
                  literals on that line get it too, so initializers like
                  {"", "minut", "dnů"} and ternary branches like
                  cond ? "pan" : "paní"  stay the same type.
                  A file is only rewritten when its content actually
                  changes; if the sole difference would be the prepended
                  UTF-8 BOM, the file is left untouched.
  -f              Force the stabilization even when the file would not
                  need it otherwise: files already starting with a UTF-8
                  BOM are processed too (including the -w widen pass),
                  and the BOM is written even when it is the only change.
  -a:<codepage>   Source ANSI codepage for files that are not already valid
                  UTF-8 (default: cp1250). Example: -a:cp1252
  file            Exact path to a file.
  pattern         Wildcard pattern: *.pas, path\\*.dfm, etc.
  @listfile       Text file listing one path or pattern per line.
                  Lines starting with # are treated as comments.

Conversion rules:
  - Files that already start with a UTF-8 BOM are considered stabilized
    and are left untouched, even when -w is given (unless -f forces it).
  - Files whose content already decodes as valid UTF-8 (without BOM) simply
    get the BOM prepended; their bytes are not re-encoded.
  - All other files are decoded using the source codepage (-a) and
    re-encoded as UTF-8.
  - If the resulting bytes are identical to the original file, the file is
    left untouched (no spurious writes / VCS changes).
  - Files are replaced atomically via a temporary file.

Exit code: 0 if all files were converted successfully, 1 if any failed.
"""

import codecs
import glob
import os
import sys

UTF8_BOM = codecs.BOM_UTF8
DEFAULT_CODEPAGE = "cp1250"


def preceded_by_text_macro(line, start):
    """True if the literal opening at line[start] is the argument of the
    TEXT()/_TEXT()/__TEXT() widening macro, e.g. TEXT("ahoj").
    Such literals must stay narrow: the macro expands to L##literal and
    an explicit L prefix would produce the invalid token LL"..."."""
    i = start - 1
    while i >= 0 and line[i] in " \t":
        i -= 1
    if i < 0 or line[i] != "(":
        return False
    i -= 1
    while i >= 0 and line[i] in " \t":
        i -= 1
    end = i
    while i >= 0 and (line[i].isalnum() or line[i] == "_"):
        i -= 1
    return line[i + 1:end + 1] in ("TEXT", "_TEXT", "__TEXT")


def widen_line(line, in_block_comment):
    """Insert L before narrow "..." literals on one line that contain
    a character outside ASCII.

    Understands // and /* */ comments, character literals ('...') and
    backslash escapes, so quotes inside those never start a string.
    Literals that already have a prefix (L"...", u8"...", macro"...")
    or are wrapped in the TEXT() macro are left alone.

    When at least one literal on the line needs the L prefix, all
    remaining eligible literals on the line get it too, so aggregate
    initializers like  {"", "minut", "dnů"}  or both branches of
    cond ? "pan" : "paní"  stay the same type. On lines with a ternary
    ? operator an already existing L"..." literal triggers this as well.

    Returns (new_line, in_block_comment) where in_block_comment is the
    comment state carried over to the next line.
    """
    inserts = []          # indexes of opening quotes that need an L
    ascii_literals = []   # eligible literals that are pure ASCII
    has_ternary = False   # saw a ? outside strings/chars/comments
    has_wide = False      # saw an existing L"..." literal
    i = 0
    n = len(line)

    while i < n:
        if in_block_comment:
            end = line.find("*/", i)
            if end == -1:
                i = n
            else:
                in_block_comment = False
                i = end + 2
            continue

        c = line[i]

        if c == "/" and i + 1 < n:
            if line[i + 1] == "/":
                break  # rest of the line is a comment
            if line[i + 1] == "*":
                in_block_comment = True
                i += 2
                continue

        if c == "'":
            # character literal: skip it, honouring escapes
            i += 1
            while i < n:
                if line[i] == "\\":
                    i += 2
                elif line[i] == "'":
                    i += 1
                    break
                else:
                    i += 1
            continue

        if c == '"':
            start = i
            # already prefixed (L"", u8"", R"", user macro"") -> leave alone
            prefixed = start > 0 and (line[start - 1].isalnum() or line[start - 1] == "_")
            if (prefixed and line[start - 1] == "L"
                    and (start < 2 or not (line[start - 2].isalnum() or line[start - 2] == "_"))):
                has_wide = True
            needs_l = False
            i += 1
            while i < n:
                if line[i] == "\\":
                    i += 2
                elif line[i] == '"':
                    i += 1
                    break
                else:
                    if ord(line[i]) > 127:
                        needs_l = True
                    i += 1
            if not prefixed and not preceded_by_text_macro(line, start):
                if needs_l:
                    inserts.append(start)
                else:
                    ascii_literals.append(start)
            continue

        if c == "?":
            has_ternary = True

        i += 1

    if ascii_literals and (inserts or (has_ternary and has_wide)):
        inserts = sorted(inserts + ascii_literals)

    if inserts:
        parts = []
        prev = 0
        for pos in inserts:
            parts.append(line[prev:pos])
            parts.append("L")
            prev = pos
        parts.append(line[prev:])
        line = "".join(parts)

    return line, in_block_comment


def add_wide_prefixes(text):
    """Apply widen_line to every line of text, keeping line endings."""
    lines = text.splitlines(keepends=True)
    in_block_comment = False
    out = []
    for raw_line in lines:
        stripped = raw_line.rstrip("\r\n")
        eol = raw_line[len(stripped):]
        new_line, in_block_comment = widen_line(stripped, in_block_comment)
        out.append(new_line + eol)
    return "".join(out)


def normalize_codepage(name):
    name = name.strip()
    if name.isdigit():
        name = "cp" + name
    codecs.lookup(name)  # raises LookupError if unknown
    return name


def convert_file(file_name, codepage, widen=False, force=False):
    """Convert file_name in-place to UTF-8 with BOM.

    With widen=True, narrow string literals containing non-ASCII
    characters also get the L prefix ("ahoj" -> L"ahoj"), and a file
    whose only difference from the result would be the prepended BOM
    is left untouched (no rewrite just to add a BOM).

    Files that already start with a UTF-8 BOM are considered stabilized
    and are not touched, not even by the widen pass.

    With force=True the file is stabilized even when it would not need
    it otherwise: files that already have a BOM are still processed
    (e.g. by the widen pass), and the BOM is written even when it would
    be the only change.

    Returns one of:
      "converted"   file was rewritten
      "unchanged"   file was already in the target format
      "skipped"     widen mode and the only change would be the BOM
      "has_bom"     file already starts with a UTF-8 BOM, kept as is
    """
    with open(file_name, "rb") as f:
        raw = f.read()

    if raw.startswith(UTF8_BOM):
        if not force:
            return "has_bom"
        body = raw[len(UTF8_BOM):]
    else:
        body = raw

    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        text = body.decode(codepage)

    if widen:
        text = add_wide_prefixes(text)

    output = UTF8_BOM + text.encode("utf-8")

    if output == raw:
        return "unchanged"

    if widen and not force and output == UTF8_BOM + raw:
        return "skipped"

    tmp_name = file_name + ".stab.tmp"
    try:
        with open(tmp_name, "wb") as f:
            f.write(output)
        os.replace(tmp_name, file_name)
    except Exception:
        if os.path.exists(tmp_name):
            os.remove(tmp_name)
        raise

    return "converted"


class Processor:
    def __init__(self, recursive, codepage, widen=False, force=False):
        self.recursive = recursive
        self.codepage = codepage
        self.widen = widen
        self.force = force
        self.success_count = 0
        self.fail_count = 0

    def process_file(self, file_name):
        sys.stdout.write("  {} ... ".format(file_name))
        try:
            result = convert_file(file_name, self.codepage, self.widen, self.force)
            messages = {
                "converted": "converted",
                "unchanged": "already up to date",
                "skipped": "skipped (only BOM would change)",
                "has_bom": "kept (already has UTF-8 BOM)",
            }
            sys.stdout.write(messages[result] + "\n")
            self.success_count += 1
        except Exception as e:
            sys.stdout.write("FAILED: {}\n".format(e))
            self.fail_count += 1

    def expand_and_process(self, pattern):
        directory = os.path.dirname(pattern) or "."
        file_pattern = os.path.basename(pattern)

        for match in sorted(glob.glob(os.path.join(directory, file_pattern))):
            if os.path.isfile(match):
                self.process_file(match)

        if self.recursive:
            try:
                subdirs = sorted(
                    entry.name for entry in os.scandir(directory) if entry.is_dir()
                )
            except OSError:
                subdirs = []
            for name in subdirs:
                self.expand_and_process(os.path.join(directory, name, file_pattern))

    def process_list_file(self, list_file_name):
        if not os.path.isfile(list_file_name):
            raise FileNotFoundError("List file not found: {}".format(list_file_name))

        with open(list_file_name, "r", encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    self.process_arg(line)

    def process_arg(self, arg):
        if arg.startswith("@"):
            self.process_list_file(arg[1:])
        elif "*" in arg or "?" in arg:
            self.expand_and_process(arg)
        else:
            self.process_file(arg)


def print_usage():
    print("Usage: code_stabilizer.py [-s] [-w] [-f] [-a:<codepage>] <file|pattern|@listfile> [...]")
    print()
    print("Converts text files in-place from an ANSI codepage to UTF-8 with BOM:")
    print("  - files already starting with a UTF-8 BOM are left untouched (even with -w)")
    print("    unless -f forces their processing")
    print("  - files that already decode as valid UTF-8 just get the BOM added")
    print("  - all other files are decoded using the source codepage and re-encoded")
    print("  - file always starts with a UTF-8 BOM after conversion")
    print()
    print("Options:")
    print("  -s              Recurse into subdirectories when expanding wildcard patterns")
    print('  -w              Add L prefix to "..." literals containing non-ASCII characters;')
    print("                  a file whose only change would be the BOM is left untouched")
    print("  -f              Force stabilization even when the file would not need it:")
    print("                  processes files that already have a BOM and writes the BOM")
    print("                  even when it is the only change")
    print("  -a:<codepage>   Source ANSI codepage for non-UTF-8 files (default: {})".format(DEFAULT_CODEPAGE))
    print()
    print("Arguments:")
    print("  file        Exact path to a file")
    print("  pattern     Wildcard pattern  (e.g.  *.pas   or   forms\\*.dfm)")
    print("  @listfile   Text file with one path/pattern per line (# = comment)")
    print()
    print("Examples:")
    print("  code_stabilizer.py MainForm.pas")
    print("  code_stabilizer.py -s *.pas")
    print("  code_stabilizer.py -a:cp1250 -s *.pas")
    print("  code_stabilizer.py -s src\\*.pas @extra_files.txt")
    print("  code_stabilizer.py @all_files.txt")


def main(argv):
    if len(argv) == 0:
        print_usage()
        return 1

    recursive = False
    widen = False
    force = False
    codepage = DEFAULT_CODEPAGE
    args = []

    for arg in argv:
        lower = arg.lower()
        if lower == "-s":
            recursive = True
        elif lower == "-w":
            widen = True
        elif lower == "-f":
            force = True
        elif lower.startswith("-a:"):
            try:
                codepage = normalize_codepage(arg[3:])
            except LookupError:
                print("Unknown codepage: {}".format(arg[3:]), file=sys.stderr)
                return 1
        else:
            args.append(arg)

    if not args:
        print_usage()
        return 1

    processor = Processor(recursive, codepage, widen, force)
    for arg in args:
        processor.process_arg(arg)

    print()
    total = processor.success_count + processor.fail_count
    if total == 0:
        print("No files matched.")
    else:
        print("{} converted, {} failed.".format(processor.success_count, processor.fail_count))

    return 1 if processor.fail_count > 0 else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
