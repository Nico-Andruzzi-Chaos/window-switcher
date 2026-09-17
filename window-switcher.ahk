#Requires AutoHotkey v2.0
; The v2 default is #SingleInstance Prompt, which pops a dialog if a startup task fires
; twice or the launcher is run again. Replace the old instance instead.
#SingleInstance Force

#Include "./logical-app.ahk"

;--------------------------------------------------------
; Alt+` to switch between windows of the same application
;--------------------------------------------------------

; This script piggybacks on the built-in Alt+Tab window switcher,
; filtering it to show only windows belonging to the same *logical application* as the
; active window -- see logical-app.ahk. That means the windows of the active Chrome
; profile, or the windows of the active PWA, rather than every window of chrome.exe.
; It listens for Alt+` and Alt+Shift+` and converts them to Alt+Tab and Alt+Shift+Tab, respectively,
; after hiding windows from the task switcher with the ITaskbarList API,
; and then unhiding them after the switcher is closed.
; Pressing ` again while holding Alt will tab through the windows of the same application,
; and Shift+` will tab through them in reverse.
; Tab or Shift+Tab also works (automatically, since that's what the switcher normally uses.)
; If app-switcher.ahk is also running, it owns the physical Alt+Tab hotkey; the two
; scripts coordinate so that neither steals keystrokes from the other, and so that the
; synthetic Alt+Tab below doesn't re-trigger the app switcher. See logical-app.ahk.

; Limitations:
; - Windows are hidden from the task bar as well, which can be distracting,
;   especially with taskbar button labels enabled, as it animates the taskbar buttons collapsing and expanding.
; - Some windows are not hidden from the task switcher, such as the Task Manager, due to permission errors.
;   - Running as administrator fixes this.
; - UWP windows (Settings, the Microsoft Store) ignore DeleteTab entirely, because Windows 11
;   builds the switcher list from the shell's application views rather than from the windows.
;   They are hidden through the view instead; see logical-app.ahk.

; TODO: remove windows from task switcher only, and not the task bar.
; Adding WS_EX_TOOLWINDOW is much faster than WinHide/WinShow (it makes the actual interaction instantaneous!),
; but it still causes distracting animation in the taskbar, particularly when taskbar button labels are enabled.
; Is there a less obtrusive way to remove windows from the task switcher?

#MaxThreadsPerHotkey 2

; Tray menu items are shared with app-switcher.ahk; see logical-app.ahk.
AddSwitcherTrayMenuItems()


; Note: window style constants and `Switchable` live in logical-app.ahk.

IID_ITaskbarList := "{56FDF342-FD6D-11d0-958A-006097C9A090}"
CLSID_TaskbarList := "{56FDF344-FD6D-11d0-958A-006097C9A090}"

ITaskbarList_VTable := {
  HrInit: 3,
  AddTab: 4,
  DeleteTab: 5,
  ActivateTab: 6,
  SetActiveAlt: 7,
}
; Create the TaskbarList object.
TaskbarList := ComObject(CLSID_TaskbarList, IID_ITaskbarList)
TaskbarListInitialized := False

TempHiddenWindows := []

; The `$` prefix forces the keyboard hook, so that these can never be triggered by
; keystrokes another AutoHotkey script generates (including this script's own).
$!+`:: {
  FilteredWindowSwitcher()
}
$!`:: {
  FilteredWindowSwitcher()
}
FilteredWindowSwitcher() {
  global TaskbarListInitialized, TempHiddenWindows
  if NativeSwitcherSessionOwnedHere() {
    ; Needs #MaxThreadsPerHotkey 2 to handle Alt+`+`+`... to tab through windows with `, while waiting for Alt to be released
    ; Needs {Blind} to handle Alt+Shift+` to go in reverse
    Send "{Blind}{Tab}"
    return
  }
  try {
    ActiveWindow := WinGetID("A")
  } catch TargetError {
    MakeSplash("Window Switcher", "Active window not found.", 1000)
    return
  }

  ; Match windows by logical application rather than by executable, so that (for
  ; example) the Google Chat PWA doesn't drag in every other chrome.exe window, and
  ; normal Chrome windows don't drag in the PWAs. See logical-app.ahk.
  ClearLogicalAppCache()
  ActiveAppId := GetLogicalAppId(ActiveWindow)
  if (ActiveAppId = "") {
    MakeSplash("Window Switcher", "Couldn't identify the active application.", 1000)
    return
  }

  AllWindows := WinGetList()
  WindowsToHide := []
  SameAppWindowCount := 0
  for Window in AllWindows {
    SameApp := false
    Hideable := false
    try {
      ; Only windows that are actually in the task switcher count. A same-app tool window
      ; would otherwise inflate the count below and make this hide every window on screen
      ; to reveal a switcher with a single real entry in it.
      InSwitcher := Switchable(Window)
      SameApp := InSwitcher && GetLogicalAppId(Window) = ActiveAppId
      Hideable := InSwitcher && !SameApp
    } catch {
      ; The window may have been destroyed while we were enumerating.
      continue
    }
    if SameApp {
      SameAppWindowCount++
    } else if Hideable {
      WindowsToHide.Push(Window)
    }
  }
  ; Nothing to switch between, so leave the native switcher (and every other window)
  ; alone. Checked before hiding anything, so this costs nothing.
  if SameAppWindowCount <= 1 {
    return
  }

  ; Assigned in the `finally` below; declared here so it always exists.
  Messages := []
  ; Held for as long as the native task switcher is up, so that app-switcher.ahk passes
  ; physical Tab presses through to it instead of opening the application switcher.
  BeginNativeSwitcherSession()
  try {
    for Window in WindowsToHide {
      Hidden := { Window: Window, Deleted: false, View: 0, ShownInSwitchers: -1 }
      try {
        if (!TaskbarListInitialized) {
          ComCall(ITaskbarList_VTable.HrInit, TaskbarList)
          TaskbarListInitialized := True
        }
        ComCall(ITaskbarList_VTable.DeleteTab, TaskbarList, "ptr", Window)
        Hidden.Deleted := true
      } catch {
        ; Deliberately silent. It's better to leave an extraneous window in the switcher than
        ; to throw an error message up while other windows are hidden. DeleteTab fails
        ; silently anyway for windows we lack the rights to touch (the Task Manager, unless
        ; running as administrator).
      }
      ; DeleteTab does nothing whatsoever for a UWP window -- it returns S_OK and leaves it
      ; in the switcher -- because Windows 11 builds that list from the shell's application
      ; views rather than from the windows themselves. Those have to be hidden through the
      ; view instead. See the notes in logical-app.ahk.
      ;
      ; Only UWP frames need this, and there are rarely more than one or two open, so the
      ; cross-process calls stay off the common path.
      try {
        NeedsView := WinGetClass(Window) = UWP_FRAME_WINDOW_CLASS
      } catch {
        NeedsView := false
      }
      if NeedsView {
        View := GetApplicationView(Window)
        if View {
          Shown := GetViewShownInSwitchers(View)
          ; Only touch a view that is currently shown, and only record it once the write
          ; has actually succeeded, so restoring can never turn on a flag that was off.
          if (Shown = 1 && SetViewShownInSwitchers(View, false)) {
            Hidden.View := View
            Hidden.ShownInSwitchers := Shown
          } else {
            ObjRelease(View)
          }
        }
      }
      if (Hidden.Deleted || Hidden.View) {
        TempHiddenWindows.Push(Hidden)
      }
    }
    ; `!` matches either Alt, so wait on whichever one is physically held. Waiting on LAlt
    ; unconditionally meant that with the *right* Alt pressed, the KeyWait found LAlt already
    ; physically up and returned instantly -- the native switcher opened and committed in the
    ; same breath, having hidden and unhidden every window for nothing. The synthetic Alt
    ; stays LAlt either way: that one is ours, and it's only there to hold the switcher open.
    PhysicalAlt := GetKeyState("LAlt", "P") ? "LAlt" : (GetKeyState("RAlt", "P") ? "RAlt" : "")
    Send "{LAlt Down}"
    Send "{Blind}{Tab}" ; Tab or Shift+Tab to go in reverse
    if PhysicalAlt {
      KeyWait PhysicalAlt
    }
  } finally {
    ; All of this has to happen even if something above threw. Leaving windows out of the
    ; taskbar and the task switcher is far worse than whatever error got us here, a stuck
    ; logical Alt is worse still, and releasing the session matters so that a failure can't
    ; leave app-switcher.ahk permanently passing Alt+Tab through to Windows.
    Messages := RestoreHiddenWindows()
    Send "{LAlt Up}"
    EndNativeSwitcherSession()
  }

  for message in Messages {
    MsgBox(message, "Window Switcher", 0x10)
  }
}

; Puts back every window removed from the task switcher, returning any error messages so
; that the caller can show them once the switcher is closed rather than mid-session.
RestoreHiddenWindows() {
  global TempHiddenWindows
  Messages := []
  for Hidden in TempHiddenWindows {
    ; The view flag first: it is the one that, left set, would keep a window out of Alt+Tab
    ; for the rest of the session.
    if Hidden.View {
      try SetViewShownInSwitchers(Hidden.View, Hidden.ShownInSwitchers)
      try ObjRelease(Hidden.View)
    }
    if Hidden.Deleted {
      try {
        ComCall(ITaskbarList_VTable.AddTab, TaskbarList, "ptr", Hidden.Window)
      } catch Error as e {
        Messages.Push("Failed to unhide window from the task switcher.`n`n" DescribeWindow(Hidden.Window) "`n`n" e.Message)
      }
    }
  }
  TempHiddenWindows.Length := 0
  return Messages
}

; DeleteTab's effect isn't tied to this process's lifetime, so if the script exits or reloads
; while windows are hidden -- Ctrl+S mid-Alt-hold, a crash, logging off -- they would stay
; missing from the taskbar until they happen to be recreated.
OnExit((*) => RestoreHiddenWindows())

;--------------------------------------------------------
; AUTO RELOAD THIS SCRIPT
;--------------------------------------------------------
~^s:: {
  if WinActive(A_ScriptName) {
    MakeSplash("AHK Auto-Reload", "`n  Reloading " A_ScriptName "  `n", 500)
    Reload
  }
}
