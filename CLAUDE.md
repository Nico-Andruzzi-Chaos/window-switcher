# Notes for Claude

## Restarting the switchers while developing

Both switchers normally run **elevated**, started at logon by a scheduled task, because
otherwise their hotkeys don't fire while an administrator window is focused. See "Running on
Startup" in the README.

Restart them through that task, never by launching the scripts:

```powershell
Start-ScheduledTask -TaskName "Start Both Window and App Switcher (as Admin)"
```

The task name is whatever the local machine calls it; `Get-ScheduledTask | Where-Object
TaskName -like "*witcher*"` finds it, and `(Get-ScheduledTask -TaskName "...").Actions` gives
the AutoHotkey interpreter path it was set up with.

That one command is a full reload of both scripts. The task starts a fresh elevated launcher,
the launcher starts fresh elevated switchers, and `#SingleInstance Force` has each new script
replace the one already running. The replacing happens elevated-to-elevated, which Windows
permits, so it works from an unelevated shell, raises no UAC prompt, and nothing needs to be
exited first.

Do **not** run `AutoHotkey64.exe window-switcher.ahk` (or the app switcher) directly while the
elevated pair is running. The new copy is unelevated, so it can't send the message that would
evict the elevated instance, and `#SingleInstance Force` silently forces nothing: two copies of
the same script end up hooking the keyboard at once, and which one sees a given keystroke
depends on which window is focused.

`logical-app.ahk` is included by both switchers, so a change there needs both restarted --
which the task does anyway.

## What an unelevated shell can and can't do

- Start and stop the task: allowed.
- Kill a switcher (`Stop-Process`): access denied, since they're elevated.
- Change the task (`Set-ScheduledTask`): access denied. Ask the user to do it in Task
  Scheduler, or from an elevated PowerShell.

## Checking a change

Parse the script without disturbing anything that's running:

```powershell
AutoHotkey64.exe /ErrorStdOut /validate window-switcher.ahk
```

Exit code 0 means it parses, 2 prints the parse error and the line. `/ErrorStdOut` is what
keeps a syntax error from opening a dialog that nobody is there to dismiss.

Then restart via the task and confirm both came up:

```powershell
Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" | Select-Object ProcessId
```

Two processes is what "both are running" looks like. Their `CommandLine` reads empty from an
unelevated shell, so which process is which script isn't visible from here.

Everything interactive is the user's to check: tray menu items, whether a hotkey fires, how the
app switcher's panel looks, the text of a `MsgBox`. Restart the pair, then ask them to press the
shortcut and say what happened, or to screenshot it.
