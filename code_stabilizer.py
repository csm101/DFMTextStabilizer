#!/usr/bin/env python3
"""
code_stabilizer.py

Command-line tool that converts text files in-place from an ANSI codepage
encoding to UTF-8 with a byte-order mark (BOM).

Argument syntax:
  code_stabilizer.py [-s] [-a:<codepage>] <file|pattern|@listfile> [...]

  -s              Recurse into subdirectories when expanding wildcard patterns.
  -a:<codepage>   Source ANSI codepage for files that are not already valid
                  UTF-8 (default: cp1250). Example: -a:cp1252
  file            Exact path to a file.
  pattern         Wildcard pattern: *.pas, path\\*.dfm, etc.
  @listfile       Text file listing one path or pattern per line.
                  Lines starting with # are treated as comments.

Conversion rules:
  - Files that already start with a UTF-8 BOM are left untouched.
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


def normalize_codepage(name):
    name = name.strip()
    if name.isdigit():
        name = "cp" + name
    codecs.lookup(name)  # raises LookupError if unknown
    return name


def convert_file(file_name, codepage):
    """Convert file_name in-place to UTF-8 with BOM.

    Returns True if the file was actually rewritten, False if it was
    already in the target format (no disk write performed).
    """
    with open(file_name, "rb") as f:
        raw = f.read()

    body = raw[len(UTF8_BOM):] if raw.startswith(UTF8_BOM) else raw

    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        text = body.decode(codepage)

    output = UTF8_BOM + text.encode("utf-8")

    if output == raw:
        return False

    tmp_name = file_name + ".stab.tmp"
    try:
        with open(tmp_name, "wb") as f:
            f.write(output)
        os.replace(tmp_name, file_name)
    except Exception:
        if os.path.exists(tmp_name):
            os.remove(tmp_name)
        raise

    return True


class Processor:
    def __init__(self, recursive, codepage):
        self.recursive = recursive
        self.codepage = codepage
        self.success_count = 0
        self.fail_count = 0

    def process_file(self, file_name):
        sys.stdout.write("  {} ... ".format(file_name))
        try:
            converted = convert_file(file_name, self.codepage)
            sys.stdout.write("converted\n" if converted else "already up to date\n")
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
    print("Usage: code_stabilizer.py [-s] [-a:<codepage>] <file|pattern|@listfile> [...]")
    print()
    print("Converts text files in-place from an ANSI codepage to UTF-8 with BOM:")
    print("  - files already starting with a UTF-8 BOM are left untouched")
    print("  - files that already decode as valid UTF-8 just get the BOM added")
    print("  - all other files are decoded using the source codepage and re-encoded")
    print("  - file always starts with a UTF-8 BOM after conversion")
    print()
    print("Options:")
    print("  -s              Recurse into subdirectories when expanding wildcard patterns")
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
    codepage = DEFAULT_CODEPAGE
    args = []

    for arg in argv:
        lower = arg.lower()
        if lower == "-s":
            recursive = True
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

    processor = Processor(recursive, codepage)
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
