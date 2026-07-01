"""
Core DFM text stabilization logic (Python port).

Ports the *text-DFM* half of DFMTextStabilizerCore.pas: parsing an existing
textual .dfm (UTF-8 with/without BOM, or a legacy single-byte ANSI code page
such as CP1250) and re-emitting it in the stabilized format used by the
Delphi DFMStabilizerTool / DFMBinaryToTextHook:

  - strings are not broken at 64 characters (limit raised to 700)
  - embedded newlines (#13/#10) cause a line break at that position
  - non-ASCII characters are written literally as UTF-8
  - file always starts with a UTF-8 BOM

Legacy *binary* DFMs (the old pre-Delphi-5 on-disk format, signature bytes
0xFF 0x0A) are intentionally out of scope for this port -- converting those
requires reimplementing Delphi's TReader/TWriter binary streaming format.
Use the original Delphi DFMStabilizerTool for those files; this module raises
UnsupportedBinaryDFMError so callers can report it clearly.
"""

from __future__ import annotations

import codecs
from dataclasses import dataclass, field
from typing import List, Optional, Tuple, Union

LINE_LENGTH = 700  # matches LineLength in DFMTextStabilizerCore.pas
BYTES_PER_LINE = 32  # matches BytesPerLine in ConvertBinary
UTF8_BOM = codecs.BOM_UTF8
NEWLINE = "\r\n"  # sLineBreak on Windows, matching the original tool's output
INDENT_UNIT = "  "


class DFMError(Exception):
    pass


class UnsupportedBinaryDFMError(DFMError):
    """Raised when the input is a legacy binary DFM (signature 0xFF 0x0A)."""


class DFMParseError(DFMError):
    pass


# ---------------------------------------------------------------------------
# Decoding raw file bytes to text
# ---------------------------------------------------------------------------


def is_binary_dfm(data: bytes) -> bool:
    return len(data) >= 2 and data[0] == 0xFF and data[1] == 0x0A


def _has_non_ascii_bytes(data: bytes) -> bool:
    return any(b > 127 for b in data)


def decode_dfm_bytes(data: bytes, ansi_code_page: Optional[int] = None) -> str:
    """
    Decode raw .dfm file bytes to text, mirroring the three text-DFM cases in
    ConvertDFMFile (BOM / explicit ANSI code page / UTF-8-without-BOM guess /
    pure ASCII). Raises UnsupportedBinaryDFMError if this is a legacy binary
    DFM instead of a text one.
    """
    if is_binary_dfm(data):
        raise UnsupportedBinaryDFMError(
            "Legacy binary DFM format is not supported by this tool; "
            "use the Delphi DFMStabilizerTool.exe for this file."
        )

    if data.startswith(UTF8_BOM):
        # Case 1: UTF-8 with BOM.
        return data[len(UTF8_BOM):].decode("utf-8")

    if ansi_code_page:
        # Case 2: caller specified the source ANSI code page explicitly.
        try:
            return data.decode(f"cp{ansi_code_page}")
        except LookupError as exc:
            raise DFMError(f"Unknown ANSI code page: {ansi_code_page}") from exc

    if _has_non_ascii_bytes(data):
        # Case 3: assume UTF-8 without BOM.
        return data.decode("utf-8")

    # Case 4: pure ASCII.
    return data.decode("ascii")


# ---------------------------------------------------------------------------
# AST
# ---------------------------------------------------------------------------

# A value is one of:
#   ("scalar", raw_text)                      -- number / ident / True / nil / etc, verbatim
#   ("string", [str])                          -- logical Unicode content of a string literal
#   ("set", [ident, ...])                      -- [Ident1, Ident2]
#   ("list", [Value, ...])                     -- (Value Value ...)
#   ("binary", hex_str)                        -- {AA00FF...}
#   ("collection", [CollectionItem, ...])      -- <item ... end item ... end>
Value = Tuple[str, object]


@dataclass
class CollectionItem:
    index: Optional[int]
    properties: List[Tuple[str, "Value"]]


@dataclass
class DFMObject:
    kind: str  # 'object' | 'inherited' | 'inline'
    name: str
    class_name: str
    position: Optional[int]
    properties: List[Tuple[str, "Value"]] = field(default_factory=list)
    children: List["DFMObject"] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

_IDENT_START = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
_IDENT_CONT = _IDENT_START | set("0123456789.")
_WS = set(" \t\r\n")
_SCALAR_STOP = set("'#(),[]<>{}=\t\r\n ")


class _Parser:
    def __init__(self, text: str):
        self.s = text
        self.i = 0
        self.n = len(text)

    # -- low-level helpers --------------------------------------------------

    def skip_ws(self) -> None:
        while self.i < self.n and self.s[self.i] in _WS:
            self.i += 1

    def peek(self) -> str:
        return self.s[self.i] if self.i < self.n else ""

    def eof(self) -> bool:
        self.skip_ws()
        return self.i >= self.n

    def expect(self, ch: str) -> None:
        self.skip_ws()
        if self.peek() != ch:
            raise DFMParseError(
                f"Expected '{ch}' at offset {self.i}, found "
                f"{self.s[self.i:self.i + 20]!r}"
            )
        self.i += 1

    def read_ident(self) -> str:
        self.skip_ws()
        start = self.i
        if self.i >= self.n or self.s[self.i] not in _IDENT_START:
            raise DFMParseError(
                f"Expected identifier at offset {self.i}, found "
                f"{self.s[self.i:self.i + 20]!r}"
            )
        self.i += 1
        while self.i < self.n and self.s[self.i] in _IDENT_CONT:
            self.i += 1
        return self.s[start:self.i]

    def peek_ident(self) -> str:
        save = self.i
        self.skip_ws()
        start = self.i
        while self.i < self.n and self.s[self.i] in _IDENT_CONT:
            self.i += 1
        word = self.s[start:self.i]
        self.i = save
        return word

    # -- object ---------------------------------------------------------

    def parse_objects(self) -> List[DFMObject]:
        objects = []
        while not self.eof():
            objects.append(self.parse_object())
            self.skip_ws()
        return objects

    def parse_object(self) -> DFMObject:
        kind = self.read_ident().lower()
        if kind not in ("object", "inherited", "inline"):
            raise DFMParseError(f"Expected object/inherited/inline, found {kind!r}")

        first = self.read_ident()
        self.skip_ws()
        if self.peek() == ":":
            self.i += 1
            name = first
            class_name = self.read_ident()
        else:
            name = ""
            class_name = first

        position = None
        self.skip_ws()
        if self.peek() == "[":
            self.i += 1
            self.skip_ws()
            start = self.i
            while self.i < self.n and self.s[self.i] != "]":
                self.i += 1
            position = int(self.s[start:self.i].strip())
            self.expect("]")

        node = DFMObject(kind=kind, name=name, class_name=class_name, position=position)

        # Properties, until we see a nested object or the closing 'end'.
        while True:
            self.skip_ws()
            word = self.peek_ident().lower()
            if word == "end":
                self.read_ident()
                return node
            if word in ("object", "inherited", "inline"):
                break
            prop_name = self.read_ident()
            self.expect("=")
            value = self.parse_value()
            node.properties.append((prop_name, value))

        # Child objects, until the closing 'end'.
        while True:
            self.skip_ws()
            word = self.peek_ident().lower()
            if word == "end":
                self.read_ident()
                return node
            if word in ("object", "inherited", "inline"):
                node.children.append(self.parse_object())
                continue
            raise DFMParseError(
                f"Expected nested object or 'end' at offset {self.i}, found "
                f"{self.s[self.i:self.i + 20]!r}"
            )

    # -- values -----------------------------------------------------------

    def parse_value(self) -> Value:
        self.skip_ws()
        c = self.peek()
        if c == "'" or c == "#":
            return self.parse_string_value()
        if c == "(":
            return self.parse_list_value()
        if c == "[":
            return self.parse_set_value()
        if c == "<":
            return self.parse_collection_value()
        if c == "{":
            return self.parse_binary_value()
        return self.parse_scalar_value()

    def parse_scalar_value(self) -> Value:
        self.skip_ws()
        start = self.i
        if self.i < self.n and self.s[self.i] == "-":
            self.i += 1
        while self.i < self.n and self.s[self.i] not in _SCALAR_STOP:
            self.i += 1
        if self.i == start:
            raise DFMParseError(
                f"Expected a value at offset {self.i}, found "
                f"{self.s[self.i:self.i + 20]!r}"
            )
        return ("scalar", self.s[start:self.i])

    def _read_quoted_literal(self) -> str:
        self.expect("'")
        buf = []
        while True:
            if self.i >= self.n:
                raise DFMParseError("Unterminated string literal")
            c = self.s[self.i]
            if c == "'":
                if self.i + 1 < self.n and self.s[self.i + 1] == "'":
                    buf.append("'")
                    self.i += 2
                    continue
                self.i += 1
                break
            if c in "\r\n":
                raise DFMParseError("Unterminated string literal (embedded newline)")
            buf.append(c)
            self.i += 1
        return "".join(buf)

    def _skip_horizontal_ws(self) -> None:
        while self.i < self.n and self.s[self.i] in (" ", "\t"):
            self.i += 1

    def parse_string_value(self) -> Value:
        # A newline WITHOUT a preceding '+' ends the string value here (the
        # writer always inserts '+' before every line break within a single
        # string -- see _serialize_string). Without that marker, a segment on
        # the next line belongs to a different value (typically the next
        # element of an enclosing list), not a continuation of this string.
        # Segments on the *same* line concatenate implicitly, with or without
        # a '+' between them.
        chars: List[str] = []
        first = True
        while True:
            if not first:
                save = self.i
                self._skip_horizontal_ws()
                c = self.peek()
                if c == "+":
                    self.i += 1
                    self.skip_ws()
                elif c in ("'", "#"):
                    pass  # same line, implicit concatenation
                else:
                    self.i = save
                    break
            first = False
            c = self.peek()
            if c == "'":
                chars.append(self._read_quoted_literal())
            elif c == "#":
                self.i += 1
                start = self.i
                while self.i < self.n and self.s[self.i].isdigit():
                    self.i += 1
                if self.i == start:
                    raise DFMParseError("Expected digits after '#'")
                chars.append(chr(int(self.s[start:self.i])))
            else:
                break
        return ("string", "".join(chars))

    def parse_list_value(self) -> Value:
        self.expect("(")
        elements: List[Value] = []
        while True:
            self.skip_ws()
            if self.peek() == ")":
                self.i += 1
                break
            elements.append(self.parse_value())
        return ("list", elements)

    def parse_set_value(self) -> Value:
        self.expect("[")
        idents: List[str] = []
        self.skip_ws()
        if self.peek() == "]":
            self.i += 1
            return ("set", idents)
        while True:
            idents.append(self.read_ident())
            self.skip_ws()
            if self.peek() == ",":
                self.i += 1
                continue
            self.expect("]")
            break
        return ("set", idents)

    def parse_binary_value(self) -> Value:
        self.expect("{")
        hex_chars = []
        while True:
            if self.i >= self.n:
                raise DFMParseError("Unterminated binary block")
            c = self.s[self.i]
            if c == "}":
                self.i += 1
                break
            if c not in _WS:
                hex_chars.append(c)
            self.i += 1
        return ("binary", "".join(hex_chars))

    def parse_collection_value(self) -> Value:
        self.expect("<")
        items: List[CollectionItem] = []
        while True:
            self.skip_ws()
            if self.peek() == ">":
                self.i += 1
                break
            word = self.read_ident().lower()
            if word != "item":
                raise DFMParseError(f"Expected 'item' inside collection, found {word!r}")
            self.skip_ws()
            index = None
            if self.peek() == "[":
                self.i += 1
                self.skip_ws()
                start = self.i
                while self.i < self.n and self.s[self.i] != "]":
                    self.i += 1
                index = int(self.s[start:self.i].strip())
                self.expect("]")

            properties: List[Tuple[str, Value]] = []
            while True:
                self.skip_ws()
                word = self.peek_ident().lower()
                if word == "end":
                    self.read_ident()
                    break
                prop_name = self.read_ident()
                self.expect("=")
                value = self.parse_value()
                properties.append((prop_name, value))

            items.append(CollectionItem(index=index, properties=properties))
        return ("collection", items)


def parse_dfm_text(text: str) -> List[DFMObject]:
    parser = _Parser(text)
    return parser.parse_objects()


# ---------------------------------------------------------------------------
# Serializer (mirrors ConvertHeader/ConvertProperty/ConvertValue/ConvertBinary
# in DFMTextStabilizerCore.pas)
# ---------------------------------------------------------------------------


def _indent(level: int) -> str:
    return INDENT_UNIT * level


def _serialize_string(content: str, level: int, out: List[str]) -> None:
    if content == "":
        out.append("''")
        return

    cur_level = level + 1
    n = len(content)
    i = 0
    k = 0

    if n > LINE_LENGTH:
        out.append(NEWLINE + _indent(cur_level))

    while i < n:
        line_break = False
        ch = content[i]
        if ch >= " " and ch != "'":
            j = i
            i += 1
            while i < n and content[i] >= " " and content[i] != "'" and (i - k) < LINE_LENGTH:
                i += 1
            if (i - k) >= LINE_LENGTH:
                line_break = True
            out.append("'")
            out.append(content[j:i])
            out.append("'")
        else:
            out.append("#")
            out.append(str(ord(ch)))
            if ch == "\n":
                line_break = True
            elif ch == "\r" and (i + 1 >= n or content[i + 1] != "\n"):
                line_break = True
            i += 1
            if not line_break and (i - k) >= LINE_LENGTH:
                line_break = True

        if line_break and i < n:
            out.append(" +")
            out.append(NEWLINE + _indent(cur_level))
            k = i


def _serialize_binary(hex_str: str, level: int, out: List[str]) -> None:
    out.append("{")
    chunk_chars = BYTES_PER_LINE * 2
    multiline = len(hex_str) >= chunk_chars
    inner_indent = _indent(level + 1)
    pos = 0
    while pos < len(hex_str):
        if multiline:
            out.append(NEWLINE + inner_indent)
        out.append(hex_str[pos:pos + chunk_chars])
        pos += chunk_chars
    out.append("}")


def _serialize_collection(items: List[CollectionItem], level: int, out: List[str]) -> None:
    out.append("<")
    item_indent = _indent(level + 1)
    prop_indent = _indent(level + 2)
    for item in items:
        out.append(NEWLINE + item_indent + "item")
        if item.index is not None:
            out.append(f" [{item.index}]")
        out.append(NEWLINE)
        for prop_name, value in item.properties:
            out.append(prop_indent + prop_name + " = ")
            _serialize_value(value, level + 2, out)
            out.append(NEWLINE)
        out.append(item_indent + "end")
    out.append(">")


def _serialize_list(elements: List[Value], level: int, out: List[str]) -> None:
    out.append("(")
    inner_indent = _indent(level + 1)
    for element in elements:
        out.append(NEWLINE + inner_indent)
        _serialize_value(element, level + 1, out)
    out.append(")")


def _serialize_value(value: Value, level: int, out: List[str]) -> None:
    kind, payload = value
    if kind == "scalar":
        out.append(payload)
    elif kind == "string":
        _serialize_string(payload, level, out)
    elif kind == "set":
        out.append("[" + ", ".join(payload) + "]")
    elif kind == "list":
        _serialize_list(payload, level, out)
    elif kind == "binary":
        _serialize_binary(payload, level, out)
    elif kind == "collection":
        _serialize_collection(payload, level, out)
    else:
        raise DFMError(f"Unknown value kind: {kind}")


def _serialize_object(node: DFMObject, level: int, out: List[str]) -> None:
    indent = _indent(level)
    out.append(indent)
    out.append({"object": "object ", "inherited": "inherited ", "inline": "inline "}[node.kind])
    if node.name:
        out.append(node.name)
        out.append(": ")
    out.append(node.class_name)
    if node.position is not None:
        out.append(f" [{node.position}]")
    out.append(NEWLINE)

    prop_indent = _indent(level + 1)
    for prop_name, value in node.properties:
        out.append(prop_indent)
        out.append(prop_name)
        out.append(" = ")
        _serialize_value(value, level + 1, out)
        out.append(NEWLINE)

    for child in node.children:
        _serialize_object(child, level + 1, out)

    out.append(indent)
    out.append("end")
    out.append(NEWLINE)


def stabilize_text(text: str) -> str:
    """Parse DFM text and re-serialize it in the stabilized format."""
    objects = parse_dfm_text(text)
    out: List[str] = []
    for obj in objects:
        _serialize_object(obj, 0, out)
    return "".join(out)


def stabilize_dfm_bytes(data: bytes, ansi_code_page: Optional[int] = None) -> bytes:
    """
    Full in-memory conversion: raw file bytes -> stabilized file bytes
    (UTF-8 BOM + stabilized text, CRLF line endings).
    """
    text = decode_dfm_bytes(data, ansi_code_page)
    stabilized = stabilize_text(text)
    return UTF8_BOM + stabilized.encode("utf-8")
