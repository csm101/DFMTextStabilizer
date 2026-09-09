"""
Command-line interface for the Python port of DFMStabilizerTool.

Argument syntax:
  dfm_stabilizer_tool.py [-s] [-a:<codepage>] <file|pattern|@listfile> [...]

  -s          Recurse into subdirectories when expanding wildcard patterns.
  -a:<cp>     Decode text DFMs with no UTF-8 BOM using ANSI code page <cp>
              (e.g. -a:1250 for Central European / Czech) instead of
              assuming UTF-8 without BOM. Use this if conversion fails with
              "No mapping for the Unicode character exists in the target
              multi-byte code page" style errors.
  file        Exact path to a DFM file.
  pattern     Wildcard pattern: *.dfm, path\\*.dfm, etc.
  @listfile   Text file listing one path or pattern per line.
              Lines starting with # are treated as comments.

Only text DFMs are supported (UTF-8 with/without BOM, or a single-byte ANSI
code page). Legacy binary DFMs (signature 0xFF 0x0A) are reported as failed;
use the original Delphi DFMStabilizerTool for those.

Exit code: 0 if all files were converted successfully, 1 if any failed.
"""

from __future__ import annotations

import fnmatch
import os
import re
import sys
from pathlib import Path
from typing import List, Optional

from dfm_text_stabilizer_core import DFMError, stabilize_dfm_bytes

ANSI_CODE_PAGE_SWITCH = "-a:"


def is_ansi_code_page_arg(arg: str) -> bool:
    return arg.lower().startswith(ANSI_CODE_PAGE_SWITCH)


def extract_ansi_code_page(arg: str) -> int:
    value = arg[len(ANSI_CODE_PAGE_SWITCH):]
    digits = "".join(re.findall(r"\d", value))
    if not digits:
        raise DFMError(f'Invalid ANSI code page: "{arg}"')
    return int(digits)


def convert_dfm_file(file_name: str, ansi_code_page: Optional[int] = None) -> bool:
    """
    Convert file_name in-place to the stabilized text format.
    Returns True if the file was rewritten, False if already up to date.
    Raises DFMError (or an OSError) on failure.
    """
    with open(file_name, "rb") as f:
        original = f.read()

    stabilized = stabilize_dfm_bytes(original, ansi_code_page)

    if stabilized == original:
        return False

    tmp_name = file_name + ".dfmstab.tmp"
    try:
        with open(tmp_name, "wb") as f:
            f.write(stabilized)
        os.replace(tmp_name, file_name)
    except Exception:
        if os.path.exists(tmp_name):
            os.remove(tmp_name)
        raise

    return True


class DFMProcessor:
    def __init__(self, recursive: bool, ansi_code_page: Optional[int]):
        self.recursive = recursive
        self.ansi_code_page = ansi_code_page
        self.success_count = 0
        self.fail_count = 0

    def process_file(self, file_name: str) -> None:
        try:
            print(f"  {file_name} ... ", end="")
            if convert_dfm_file(file_name, self.ansi_code_page):
                print("converted")
            else:
                print("already up to date")
            self.success_count += 1
        except Exception as exc:  # noqa: BLE001 - mirror the Delphi try/except-per-file behavior
            print(f"FAILED: {exc}")
            self.fail_count += 1

    def expand_and_process(self, pattern: str) -> None:
        directory = os.path.dirname(pattern) or "."
        file_pattern = os.path.basename(pattern)

        if os.path.isdir(directory):
            try:
                entries = sorted(os.listdir(directory))
            except OSError:
                entries = []
            for entry in entries:
                full_path = os.path.join(directory, entry)
                if os.path.isfile(full_path) and fnmatch.fnmatch(entry, file_pattern):
                    self.process_file(full_path)

            if self.recursive:
                for entry in entries:
                    full_path = os.path.join(directory, entry)
                    if os.path.isdir(full_path):
                        self.expand_and_process(os.path.join(full_path, file_pattern))

    def process_list_file(self, list_file_name: str) -> None:
        if not os.path.isfile(list_file_name):
            raise FileNotFoundError(f"List file not found: {list_file_name}")

        with open(list_file_name, "r", encoding="utf-8-sig") as f:
            lines = f.readlines()

        for line in lines:
            line = line.strip()
            if line and not line.startswith("#"):
                self.process_arg(line)

    def process_arg(self, arg: str) -> None:
        if arg.startswith("@"):
            self.process_list_file(arg[1:])
        elif "*" in arg or "?" in arg:
            self.expand_and_process(arg)
        else:
            self.process_file(arg)


def print_usage() -> None:
    print("Usage: dfm_stabilizer_tool.py [-s] [-a:<codepage>] <file|pattern|@listfile> [...]")
    print()
    print("Converts DFM files in-place to the stabilized UTF-8 text format:")
    print("  - strings are not broken at 64 characters (limit raised to 700)")
    print("  - embedded newlines (#13/#10) cause a line break at that position")
    print("  - non-ASCII characters are written literally as UTF-8")
    print("  - file always starts with a UTF-8 BOM")
    print()
    print("Only text DFMs are supported (legacy binary DFMs are reported as failed;")
    print("use the Delphi DFMStabilizerTool.exe for those).")
    print()
    print("Options:")
    print("  -s          Recurse into subdirectories when expanding wildcard patterns")
    print("  -a:<cp>     Decode text DFMs with no UTF-8 BOM using ANSI code page <cp>")
    print("              (e.g. -a:1250 for Central European / Czech) instead of")
    print("              assuming UTF-8 without BOM. Use this if conversion fails with")
    print('              "No mapping for the Unicode character exists in the target')
    print('              multi-byte code page".')
    print()
    print("Arguments:")
    print("  file        Exact path to a DFM file")
    print("  pattern     Wildcard pattern  (e.g.  *.dfm   or   forms\\*.dfm)")
    print("  @listfile   Text file with one path/pattern per line (# = comment)")
    print()
    print("Examples:")
    print("  dfm_stabilizer_tool.py MainForm.dfm")
    print("  dfm_stabilizer_tool.py -s *.dfm")
    print("  dfm_stabilizer_tool.py -s src\\*.dfm @extra_forms.txt")
    print("  dfm_stabilizer_tool.py @all_forms.txt")
    print("  dfm_stabilizer_tool.py -a:1250 legacy\\*.dfm")


def run(argv: Optional[List[str]] = None) -> int:
    args = sys.argv[1:] if argv is None else argv

    if not args:
        print_usage()
        return 1

    recursive = False
    ansi_code_page: Optional[int] = None
    for arg in args:
        if arg == "-s":
            recursive = True
        elif is_ansi_code_page_arg(arg):
            try:
                ansi_code_page = extract_ansi_code_page(arg)
            except DFMError as exc:
                print(f"Fatal: {exc}", file=sys.stderr)
                return 1

    processor = DFMProcessor(recursive, ansi_code_page)
    for arg in args:
        if arg == "-s" or is_ansi_code_page_arg(arg):
            continue
        processor.process_arg(arg)

    print()
    total = processor.success_count + processor.fail_count
    if total == 0:
        print("No files matched.")
    else:
        print(f"{processor.success_count} converted, {processor.fail_count} failed.")

    return 1 if processor.fail_count > 0 else 0
