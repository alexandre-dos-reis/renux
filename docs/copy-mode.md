# Copy mode

Enter with **Ctrl+Shift+Space** on Linux, or **Shift+Command+C** on macOS. You can change
that shortcut in Settings > Shortcuts, including removing it, or add a binding in Rex:

```lua
rex.bind("ctrl+a>[", "pane.copy_mode.enter")
```

Renux sends the entry binding as a client-default layer in `client.keymap`, below the Rex
config. Renux's recorded shortcuts are applied above that resolved map, as for other actions.
The rig's Rex API 17 server returns no copy-mode bindings of its own for an empty request:
these are client actions, not server terminal commands. No server mode is entered and no
copy-mode input is sent to the program.

## Keys

| Keys | What they do |
|---|---|
| `h j k l`, arrows | Move left, down, up, right, by terminal cell/physical row |
| `w b e` | Next word, previous word, end of word; punctuation is separate |
| `W B E` | The same, with words separated only by whitespace |
| `0`, Home | Start of the logical line |
| `^` | First nonblank character of the logical line |
| `$`, End | Last nonblank character of the logical line |
| `H M L` | Top, middle, bottom of the visible screen |
| `Ctrl+U`, `Ctrl+D` | Half a screen up/down |
| `Ctrl+B`, Page Up / `Ctrl+F`, Page Down | A screen up/down |
| `g`, `G` | First/last row of the scrollback; `12g` or `12G` chooses row 12 |
| `{`, `}` | Previous/next blank paragraph boundary |
| `1`–`9`, then `0`–`9` | A count for the next motion, search or character find |
| `v`, `V`, `Ctrl+V` | Character, whole-logical-line, rectangle selection |
| `o` | Move the cursor to the selection's other end |
| `/`, `?` | Type a forward/backward literal, case-sensitive search; Enter runs it |
| Backspace, Escape while typing a search | Edit the query, or cancel it without losing the previous query |
| `n`, `N` | Repeat the last search in its original/opposite direction |
| `f`, `F`, then a character | Find the character forward/backward in the logical line |
| `t`, `T`, then a character | Find it but stop one character before/after it |
| `;`, `,` | Repeat/reverse the character find |
| `y`, Enter | Copy the selection and leave; without a selection, just leave |
| `D` | Copy from the cursor through the end of the logical line and leave |
| Escape, `q` | Leave without copying and restore the original viewport |

Pressing the active selection key again removes the selection; choosing another selection
kind keeps its anchor. Selection endpoints are inclusive. Counts are capped at 100,000 to
bound accidental input. Searches wrap around the scrollback; a missing match leaves the
cursor in place and says “not found” in the mode chip.

This follows Rex's published Mac action table, including its single `g` top-of-history
motion (not Vim's `gg`). The Linux entry key differs because Ctrl+Shift+C already copies
mouse selections and desktop Super shortcuts can intercept the Mac key. The Mac default is
unchanged. Escape cancels an open search first; a second Escape leaves copy mode.

## Text, wrapping and incoming output

Copy mode reads a private Ghostty snapshot of the terminal, including its scrollback. New
output continues in the live terminal but cannot move the copy cursor, evict its history,
or alter selected text. Leaving discards that snapshot and returns to the live terminal's
original viewport (following its current bottom if that was the original position).

- A wide character is one cursor stop; its spacer cell cannot become the cursor.
- Combining marks remain attached when copied. Motions and search compare a cell's primary
  codepoint; searches do not normalize Unicode or separately match combining marks.
- `j/k`, arrows and page motions use physical rows. Word motions cross wrapped rows without
  a word break; an explicit newline is a word boundary.
- `0/^/$`, line selections, `D`, and character finds use logical lines, including all their
  soft-wrapped rows. Character selection copies soft wraps without a newline, just as mouse
  selection does. Rectangles use columns and physical rows.
- Formatting, trimming, clipboard ownership, and the selection's colors/rounded corners all
  use the existing terminal selection path. Whole-line yanks have no extra final newline,
  matching that path.
- The snapshot keeps its original grid if the pane is resized. Exit and re-enter to use the
  new grid. Taking a snapshot can fail while a VT/UTF-8 update is incomplete; Renux reports
  that and asks you to try again, rather than selecting different text.

## Actions and configuration

All thirteen `pane.copy_mode.*` action names are handled. Rex's public table and the rig's
API do not expose the Mac client's argument schemas. The following are **Renux's local
arguments**, not a guessed claim of Mac argument compatibility:

| Action suffix | Arguments |
|---|---|
| `enter`, `exit`, `swap_ends`, `yank`, `copy_to_line_end` | None |
| `move` | `motion`: one of the names below |
| `select` | `kind`: `character` (default), `line`, `rectangle` |
| `search` | `backward`: boolean, default false; opens query entry |
| `search_again` | `reverse`: boolean, default false |
| `find` | `backward`, `till`: booleans, default false; waits for a character |
| `find_again` | `reverse`: boolean, default false |
| `count` | `digit`: integer 0–9; an initial zero moves to line start |

Motion names:

```text
left right up down
word_forward word_backward word_end
WORD_forward WORD_backward WORD_end
line_start first_nonblank line_end
screen_top screen_middle screen_bottom
half_up half_down page_up page_down
top bottom paragraph_up paragraph_down
```

Bindings in the Rex mode named `copy` can override individual built-in keys. Search-query
text and the character after `f/F/t/T` belong to their prompts instead of those overrides:

```lua
rex.bind("copy/s", "pane.copy_mode.select", { kind = "line" })
rex.bind("copy/J", "pane.copy_mode.move", { motion = "half_down" })
```

The built-in Vim keys are deliberately pane-local: a different pane still accepts normal
terminal input. The existing mode chip shows copy status only for the focused pane. Escape
or `q` leaves copy mode; generic Rex key-mode exit actions concern Rex's separate key modes.

## Checks

`zig build test` includes the GTK-free motion tests in `src/terminal/copymode.zig` and the
Ghostty snapshot/selection tests in `src/terminal/term.zig`. These cover counts, words,
punctuation, wrapping, wide characters, combining-mark copying, selection kinds, searches,
find/till repetition and page/screen boundaries.

With a development build and the private UI rig, `copy-state` in `$RENUX_SCRIPT` logs the
cursor/anchor/mode and `clipboard` asynchronously logs the actual GDK clipboard contents.
`rex ACTION {JSON}` invokes an action with arguments. Real input still needs to go through
the rig's fake-input tool to exercise GTK/IM routing rather than only those script hooks.
