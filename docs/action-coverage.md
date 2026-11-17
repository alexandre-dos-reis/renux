# Rex action coverage

Compared against the **Mac Actions** tables at
https://www.superlogical.com/rex/docs/reference/mac-actions (2026-11-17), not just a
comparison of literal strings. `pane.focus.*`, `pane.split.*` and `pane.move.*` use
prefix routing; pane names reach `paneAction` without `pane.`. There are 130 command names
and 85 Mac settings names (215 total). The settings table is separate from terminal commands.

## The small-action audit

| Action | Result |
| --- | --- |
| `client.quick_look` | Added. Lists unique file paths and links on the focused pane's visible screen, including OSC 8 links. Choose a file to open its peek. Web links open the desktop browser; Renux has no embedded web viewer. |
| `client.tab.mute` | Added. Toggles desktop notifications, activity sounds and launcher-badge contributions for this tab, in this Renux process. Activity remains visible in the board and tabs. |
| `client.host.switch` | Added. Chooses among connected/configured Renux hosts. |
| `client.host.remove` | Added. Confirms before disconnecting and forgetting the shown host in Renux. Does not stop the host's sessions or change `rex hosts`. |
| `client.server.restart` | Deferred pending a safe restart policy. The installed CLI has stop/start, not restart; starting again uses defaults and cannot recover custom startup flags from server status. Stopping ends every running program. |
| `session.refresh` | Added. Re-reads the session list and known session views, including an empty list. |
| `pane.copy_id` | Already implemented, added palette fallback. |
| `pane.select_all` | Already implemented, includes scrollback; added palette fallback. |
| `pane.close_others` | Already implemented, added palette fallback. |
| `pane.rename` | Already implemented, added palette fallback. |
| `pane.new_floating` | Already implemented, added palette fallback. |
| `pane.minimize_floating` | Already implemented, added palette fallback. |
| `pane.minimize_all_floating` | Already implemented, added palette fallback. |
| `pane.move_to_tab` | Already implemented, with an index or a tab picker; added palette fallback. |
| `pane.move_to_new_tab` | Already implemented, added palette fallback. |
| `pane.insert_path` | Already implemented, host-side browser; added palette fallback. |
| `pane.go_to_directory` | Already implemented, host-side browser; added palette fallback. |
| `pane.copy`, `pane.paste` | Missing from the action router despite existing right-click and keyboard clipboard handlers. Added routing to those handlers and palette fallbacks. |

Fallback palette entries appear only when the server hasn't already supplied a titled
entry, so configured descriptions and shortcuts win. Session commands now use the same
local route in the palette as in key bindings.

## The rest of the action tables

- Window/app, session, tab, pane navigation/layout, find, font, theme/config and mode
  actions already route through `performInner`, `moreActions`, `paneAction` and existing
  app actions. `client.key.forward` is handled separately in the terminal binding path;
  it needs the physical key that invoked it.
- `client.permissions` is Mac-specific (TCC); Linux has no matching system permission
  grant screen. It remains unsupported.
- `client.toolbar.reveal` and `client.pane_header.reveal` remain unsupported: Renux does
  not have the Mac app's auto-hiding toolbar/header model. Use Renux's sidebar and pane
  header settings instead.
- The `client.setting.*` names belong to the Mac app's settings schema. They remain
  unsupported; Linux settings use Renux's Settings dialog, not that schema. No Mac
  preferences are silently mapped to unrelated Linux values.
- `client.update.*` is intentionally excluded: the Mac updater is not Renux's updater.
- `client.host.forward_port` and `pane.copy_mode.*` are intentionally excluded: separate
  work owns these actions.

Muting is client-local and lasts for this run. It does not alter the server's status or
other clients' notifications. Host removal identifies the host captured when the dialog
opened, even if selection changes before the answer. Quick Look and Switch Host use the same
`filterdialog` builder, search keys, `goto-row`, `goto-detail` and `goto-kind` styling as
Go to Anything. The existing close-session dialog now explicitly maps Escape to Cancel;
its default close-response ID had previously also been the destructive response ID.
