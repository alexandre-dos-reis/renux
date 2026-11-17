# Keep awake while an agent is working

Settings > Server > Agents has **Keep this computer awake while an agent is working**,
off by default. The setting is saved as `keep-awake-while-working` in `settings.ini`.
It uses the same bound switch helper and preferences group as the other Server settings.

Renux holds one `gtk_application_inhibit` request with **suspend** and **idle** flags,
not one per agent. A pane counts only when it has a current program-status record whose
state is `working`. A known agent name, a progress bar or a stale state without its record
is not enough. Blocked, done, failed, idle and missing statuses do not count. Programs
reporting status are treated alike, including agents Renux doesn't recognize by name.

All known panes in session views count, including background tabs, floating/minimized
panes and other connected hosts. The active host, visible tab and notification settings
do not narrow this search. Closed panes/sessions whose block details remain cached do not
count. A disconnected host stops contributing until it reconnects; a detached block outside
any session window is not a pane in this view model and does not contribute.

The request is released when no such pane remains, when the setting goes off (including
an external settings-file change), when its host is removed/disconnects, or before the
window closes. Release must happen on the window's close request: GTK has already cleared
its inhibitor backend by application shutdown. Normal process exit also clears GTK's
requests automatically. There is no logout or user-switch inhibitor.

This asks the desktop; it cannot promise that a lid-close policy, manual suspend, forced
sleep or an unsupported session manager will honour the request. A refused request is
logged once per working interval; turning the setting off/on allows another attempt.
Development builds log acquisition and release so transitions can be checked without
actually suspending a machine.

## Checks

- Unit tests cover working versus all other states, missing status, progress-only state,
  an off setting, a background pane, disconnection and a closed session with cached status.
- The settings round-trip test covers off by default and saving/reloading the enabled value.
- An isolated KWin/Rex rig with two OSC-7501 stand-in agents checks one shared inhibitor,
  release only after both stop, switch off/on, and a clean window close while working.
- The rig has no real laptop/session-manager suspend policy. Actual prevention of physical
  suspend or idle sleep must be checked on a desktop that supports GTK inhibition.
