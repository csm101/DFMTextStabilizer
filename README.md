# DFMBinaryToTextHook

A Delphi IDE plugin that improves the readability of `.dfm` files and reduces merge conflicts when working in a team.

---

## The Problem

Delphi saves `.dfm` files using `ObjectBinaryToText`, a function in `System.Classes` that converts the in-memory binary representation of a form into the text format stored on disk. By default, this function has behaviours that make `.dfm` files unnecessarily hard to read and diff.

A concrete example shows the difference. Consider a form with a label and a SQL query.

**Plain Delphi:**

```pascal
object Form1: TForm1
  object Label1: TLabel
    Caption = 'Warning: lowering this threshold causes performa' +
      'nce degradation. Contact tech support.'#13#10'Minimum' +
      ' recommended value: 5 seconds. Current setting: '#39'Au' +
      'to'#39'.'
  end
  object Label2: TLabel
    Caption = #931#966#940#955#956#945' / '#1054#1096#1080#1073#1082#1072
  end
  object DataSet1: TDataSet
    SQL.Strings = (
      'SELECT order_id, order_date, customer, total_am' +
      'ount'
      'FROM orders'
      'WHERE order_date >= :StartDate AND status = '#39'A'#39)
  end
end
```

Problems with this output:

- **Strings are broken every 64 characters**, mid-syllable, with no regard for word boundaries: `performa` / `nce`, `total_am` / `ount`, `'Au` / `to'`. The 64-character limit is arbitrary and hardcoded into `ObjectBinaryToText`.
- **Non-ASCII characters are replaced by `#xxx` escape sequences**: every character outside ASCII becomes an opaque numeric code. `Label2.Caption` is `'Σφάλμα / Ошибка'` (Greek and Russian for "Error") — completely unrecognisable in the file and unsearchable with any tool.
- **Embedded newlines are invisible**: the `#13#10` that separates the two sentences of `Label1.Caption` is buried mid-line among other fragments; there is no visual cue that a line break exists there at all.
- **Reformatting cascades silently**: the 64-character wrap depends on the exact byte offset of each string within its line. Adding or removing even a few characters anywhere in a string causes all subsequent continuation lines to shift and be rewritten — even if their content did not change. Two developers editing different properties on the same form can end up with a conflict on lines neither of them intentionally touched.
- **Merge conflicts are a nightmare to resolve**: when a conflict does occur, the diff shows a wall of `+` and `-` lines made of mangled string fragments. If the conflicting property is a SQL query — which a developer carefully formatted across multiple `Lines.Strings` entries with one clause per line — the 64-character wrap has already destroyed that structure: keywords, table names and conditions are split mid-word at arbitrary positions. The conflict markers land inside quoted literals, mid-syllable. Reconstructing what each side actually intended requires mentally re-assembling several broken fragments simultaneously, which is error-prone even for a simple query and practically infeasible for anything complex.

**With this plugin:**

```pascal
object Form1: TForm1
  object Label1: TLabel
    Caption = 'Warning: lowering this threshold causes performance degradation. ' +
      'Contact tech support.'#13#10 +
      'Minimum recommended value: 5 seconds. Current setting: '#39'Auto'#39'.'
  end
  object Label2: TLabel
    Caption = 'Σφάλμα / Ошибка'
  end
  object DataSet1: TDataSet
    SQL.Strings = (
      'SELECT order_id, order_date, customer, total_amount'
      'FROM orders'
      'WHERE order_date >= :StartDate AND status = '#39'A'#39)
  end
end
```

How this plugin addresses each of those problems:

- **Strings stay on one line** up to 700 characters — long enough for any realistic property value, short enough to stay below the hard limits of Delphi's own editor components. The arbitrary 64-character fragmentation disappears entirely.
- **Strings that contain embedded newlines break at those newlines**, and nowhere else. A SQL query formatted with one clause per line in `Lines.Strings` is saved with one clause per line. What the developer wrote is what appears in the file.
- **Non-ASCII characters are written literally as UTF-8**. `'Σφάλμα / Ошибка'` is exactly what you see in the file and exactly what `git grep` finds. No mental decoding required.
- **Diffs contain only real changes**. Because lines no longer shift when nearby content changes length, two developers editing different parts of the same form produce non-overlapping diffs. Merge conflicts, when they do occur, are between readable lines of actual content — not between interleaved fragments of a string that was sliced at column 64.

---

## What This Plugin Does

It installs runtime hooks on two functions in `System.Classes`:

| Hook | Direction | Purpose |
|------|-----------|---------|
| `ObjectBinaryToText` | binary → text (on save) | Applies the three formatting improvements |
| `ObjectTextToBinary` | text → binary (on "View as Form") | Guards against BOM loss in the text editor |

### Changes made by the `ObjectBinaryToText` hook

| Change | Default Delphi behaviour | With this plugin |
|--------|--------------------------|-----------------|
| String line break limit | 64 characters | 700 characters |
| Break at embedded newlines | No | Yes — `#13#10`, `#13`, `#10` each force a line break at that position |
| Non-ASCII characters in strings | Written as `#xxx` numeric escapes | Written literally as UTF-8 |
| UTF-8 BOM | Never written (file is always pure ASCII) | Always written |

The UTF-8 BOM is a direct consequence of writing non-ASCII characters literally (the previous row): once the file contains bytes above 127, it is no longer pure ASCII and its encoding must be declared unambiguously. The BOM (`$EF $BB $BF`) is the standard mechanism for this in the Delphi toolchain — the command-line compiler and other tools use it to distinguish UTF-8 files from ANSI files.

The hook is a **complete, self-contained reimplementation** of `ObjectBinaryToText`, not a wrapper. It does not call the original function; it replaces it entirely for the lifetime of the IDE session. All other aspects of the DFM format — binary data blocks, collections, numeric values, identifiers, the object/inherited/end structure — are preserved exactly as Delphi produces them.

### The `ObjectTextToBinary` hook — BOM guard

The Delphi IDE includes a text editor that can display the raw content of a `.dfm` file ("Text Form" view, accessible from the right-click menu in the form designer). When this editor is active, the user can edit the DFM source directly.

The UTF-8 BOM (`$EF $BB $BF`) written at the start of the file by this plugin causes a cosmetic glitch in that editor: in Delphi versions up to and including Athens, the BOM bytes are not stripped before display and appear as a partial character on the very first line, visually overlapping with the `object` keyword. More recent versions have not been verified yet. The file is otherwise displayed and edited correctly.

A developer who notices this artefact might attempt to "fix" the first line by deleting and retyping it — inadvertently erasing the BOM in the process. As long as the developer stays in the text editor and then saves (`Ctrl+S`), the BOM is restored on the next save cycle by the `ObjectBinaryToText` hook. However, if the developer switches back to the form designer ("View as Form") before saving, the IDE calls `ObjectTextToBinary` to reconstruct the in-memory binary form from the editor buffer. Without the BOM, the original `ObjectTextToBinary` would interpret the UTF-8 bytes as ANSI and **silently corrupt all non-ASCII characters in memory** — entirely in RAM, with no file I/O involved.

The `ObjectTextToBinary` hook prevents this: it inspects the incoming buffer, and if it finds non-ASCII bytes without a preceding BOM, it transparently prepends the BOM in a temporary in-memory stream before delegating to the original function. The form is loaded correctly regardless of whether the user deleted the BOM.

---

## How It Works

The Delphi IDE save pipeline for a form looks like this:

```
User presses Ctrl+S
    |
    v
Form designer serializes the form to a binary stream      (TWriter)
    |
    v
ObjectBinaryToText converts the binary stream to text     (System.Classes)  <-- hooked
    |
    v
The text is written to the .dfm file on disk
```

When the user switches from "Text Form" view back to the form designer:

```
User selects "View as Form"
    |
    v
ObjectTextToBinary converts the editor buffer to binary   (System.Classes)  <-- hooked
    |
    v
The form designer reconstructs the form from the binary stream
```

Both hooks are installed using [DelphiDetours](https://github.com/MahdiSafsafi/DDetours), which patches the machine code of the target functions in memory at IDE startup. The function addresses are resolved by name via `GetProcAddress` on the already-loaded RTL BPL, which works correctly on both 32-bit and 64-bit IDE builds:

```pascal
GTrampoline := InterceptCreate(CRTLModuleName,            // e.g. 'rtl290.bpl'
                               CObjectBinaryToTextSymbol, // mangled export name
                               @HookedObjectBinaryToText);
```

The trampolines are retained only to allow `InterceptRemove` to cleanly uninstall the hooks when the package is unloaded.

---

## Requirements

- Delphi / RAD Studio
- [DelphiDetours](https://github.com/MahdiSafsafi/DDetours) installed and available in the IDE library path
- A design-time package (`.dpk`) to host the plugin

---

## Integration

Add `DFMBinaryToTextHook.pas` to your existing design-time package. The `Register` procedure installs both hooks automatically; the `finalization` section of the unit removes them when the package is unloaded:

```pascal
unit MyIDEPlugin;

interface

procedure Register;

implementation

uses
  DFMBinaryToTextHook;

procedure Register;
begin
  // ... your existing registrations ...
  // DFMBinaryToTextHook.Register installs both hooks
end;

end.
```

Alternatively, call the procedures explicitly if you need finer control:

```pascal
uses DFMBinaryToTextHook;

// in your Register or initialization:
InstallDFMBinaryToTextHook;
InstallDFMTextToBinaryHook;

// in your finalization:
UninstallDFMTextToBinaryHook;
UninstallDFMBinaryToTextHook;
```

No other configuration is needed. Once the package is installed in the IDE, every subsequent `.dfm` save will use the new formatting.

---

## Compatibility

This plugin has been tested on Studio 23.0 / Delphi 12 Athens, in both the 32-bit IDE and the 64-bit IDE.

The hooks target functions in `System.Classes` that have been structurally unchanged since Delphi 6. The reimplementation handles all known `TValueType` variants. The DFM binary format it reads is the same format Delphi has used for decades.

The RTL BPL name (needed to resolve the export) follows the pattern `rtlNNN.bpl` where `NNN = VER_constant - 70`. The unit contains a compile-time `{$IF}` chain covering Delphi XE through Delphi 13 Florence. If you need to add support for a version not listed, add the corresponding entry to the chain and verify the export name by inspecting the BPL with `dumpbin /exports`.

When upgrading to a new version of Delphi, diff the new `System.Classes.pas` against the version this plugin was based on (Studio 23.0). If `ObjectBinaryToText` has not changed, the plugin requires no update. If new `TValueType` variants were added, extend the `case` statement in `ConvertValue` accordingly.

---

## What It Does Not Change

- The binary DFM format read by the Delphi compiler at build time is not affected.
- `.dfm` files produced by this plugin are fully valid and readable by any version of Delphi that supports UTF-8 text DFMs (Delphi 2009 and later).
- The visual appearance of forms at design time and at runtime is identical.
- No changes are made to the Delphi installation or to any file on disk other than the `.dfm` files you explicitly save.

---

## Disclaimer: Delphi Text Form editor and BOM

In Delphi versions up to and including Athens, the Text Form editor ("View as Text") does not hide the UTF-8 BOM correctly and may render it as a stray/partial character on the first line. More recent versions have not been verified yet. This is an editor UI issue, not a DFM format issue.

In practice, this does **not** cause real problems unless someone manually edits the first line in Text Form view. The most common side effect is that the caret position on that line is visually misaligned.

If the first line is edited, deleted, or fully retyped and the BOM is accidentally removed, this plugin still protects the round-trip: before delegating to `ObjectTextToBinary`, it detects non-ASCII content without BOM and transparently re-adds the BOM in memory.

So even in the worst case (first line rewritten), no data corruption occurs because of this plugin's BOM guard. Also, manually editing the first DFM line is a relatively rare operation in normal workflows.

---

## Batch conversion tool

The repository also includes `DFMStabilizerTool`, a standalone command-line utility that converts existing `.dfm` files to the stabilized format in bulk. This is useful when first adopting the plugin on a repository that already contains many forms: run the tool once to bring all files to the new format, then install the plugin so the IDE keeps them there on every subsequent save.

The tool shares the same conversion logic as the plugin (`DFMTextStabilizerCore.pas`), so the output is guaranteed to be identical to what the IDE would produce. Files that are already in the stabilized format are detected by a byte-for-byte comparison and left untouched, avoiding spurious VCS changes.

### Usage

```
DFMStabilizerTool [-s] <file|pattern|@listfile> [...]
```

| Argument | Description |
|----------|-------------|
| `file` | Exact path to a `.dfm` file |
| `pattern` | Wildcard pattern, e.g. `*.dfm` or `forms\*.dfm` |
| `@listfile` | Text file listing one path or pattern per line (`#` = comment) |
| `-s` | Recurse into subdirectories when expanding wildcard patterns |

**Examples:**

```
# Convert a single file
DFMStabilizerTool MainForm.dfm

# Convert all .dfm files in the current directory
DFMStabilizerTool *.dfm

# Convert all .dfm files recursively from the current directory downward
DFMStabilizerTool -s *.dfm

# Convert a specific subtree
DFMStabilizerTool -s src\forms\*.dfm

# Convert files listed in a text file
DFMStabilizerTool @all_forms.txt

# Mix patterns and list files
DFMStabilizerTool -s *.dfm @extra_forms.txt
```

The tool exits with code 0 if all files were converted (or were already up to date), and with code 1 if any file failed. Failed files are reported individually and do not interrupt processing of the remaining ones.

### Requirements

`DFMStabilizerTool` is a pure RTL console application. It has no dependency on DelphiDetours or on any IDE package — compile it with any version of Delphi supported by the plugin.

---

## License

This project is licensed under the MIT License.

See the `LICENSE` file for the full text.

---

## Third-party dependency

This project uses DelphiDetours:

- https://github.com/MahdiSafsafi/DDetours

When redistributing this project, keep compliance with DelphiDetours licensing terms as well.
