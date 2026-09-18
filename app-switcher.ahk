#Requires AutoHotkey v2.0
; The v2 default is #SingleInstance Prompt, which pops a dialog if a startup task fires
; twice or the launcher is run again. Replace the old instance instead.
#SingleInstance Force

#Include "./logical-app.ahk"
#Include "./app-switcher-style.ahk"

;--------------------------------------------------------
; App Switcher
;--------------------------------------------------------
; Press Alt+Tab to cycle through open applications.
; Press Shift+Alt+Tab to cycle backwards.
; Release Alt to switch to the selected application.
; Press Escape to close the app switcher.
;
; This replaces Windows' own Alt+Tab. Use Alt+` (window-switcher.ahk) to switch
; between the windows of whichever application is currently active.
;
; One entry is shown per *logical application* -- not per window, and not per process.
; Ten Chrome windows are one entry, while installed PWAs such as Google Chat and
; Google Meet get their own entries even though they all run under chrome.exe.
; See logical-app.ahk for how that identity, and each app's name and icon, are found.

;--------------------------------------------------------
; Windows API constants
;--------------------------------------------------------
; Note: window style, icon and app model constants live in logical-app.ahk,
; alongside the functions that use them.

SS_WORDELLIPSIS := 0x0000C000
SS_NOPREFIX := 0x00000080

; The panel's rounded corners and its translucent 1px border both come from DWM rather than from
; anything here. See `ApplyAppSwitcherFrame` in app-switcher-style.ahk.

; https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
; 17, not 16. DWMWINDOWATTRIBUTE is one-based (DWMWA_NCRENDERING_ENABLED is 1), so 16 is
; DWMWA_PASSIVE_UPDATE_MODE -- which is what this used to set, telling DWM to stop updating
; the window from its redirection surface instead of enabling the host backdrop brush. That
; is a plausible cause of the "blur-behind doesn't work the first time" problem below.
DWMWA_USE_HOSTBACKDROPBRUSH := 17
DWMWA_SYSTEMBACKDROP_TYPE := 38
; https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwm_systembackdrop_type
DWMSBT_TRANSIENTWINDOW := 3

;--------------------------------------------------------
; Tray Menu
;--------------------------------------------------------
; Shared with window-switcher.ahk; see logical-app.ahk.

AddSwitcherTrayMenuItems()

;--------------------------------------------------------

global AppSwitcher := 0
; Set by the Escape hotkey (and the Gui's Escape event) so that releasing Alt afterwards
; commits nothing. Reset for each new switcher session in `ShowAppSwitcher`.
global AppSwitcherCancelled := false
global FocusRingByHWND := Map()

; Build the AUMID-to-shortcut index that names and illustrates PWAs ahead of time, so
; that the first Alt+Tab isn't the one that waits for it. (A negative period means
; "run once", and the delay keeps it out of the way of startup.)
SetTimer(PrimeAppShortcutIndex, -3000)

#MaxThreadsPerHotkey 2 ; Needed to handle tabbing through apps while the switcher is open

; `AnchorWindow` is the window to place the panel next to -- the one that was active before the
; switcher opened. `Warmup` shows it without activating it, for the DWM warm-up below.
ShowAppSwitcher(Apps, AnchorWindow := 0, Warmup := false) {
	CloseAppSwitcher()  ; just in case - don't want to leave behind an old app switcher window

	global AppSwitcherCancelled := false  ; a fresh session starts out uncancelled
	; Otherwise stale entries pile up for the lifetime of the script -- one per app per
	; session -- each holding a control belonging to a Gui that no longer exists.
	FocusRingByHWND.Clear()
	; Cleared alongside the map it indexes into: it points at a control of the Gui that
	; `CloseAppSwitcher` above just destroyed.
	global LastFocusHighlight := 0

	; Everything below comes out of app-switcher-style.ahk, which holds the presentation values
	; measured off the real Windows 11 Alt+Tab switcher, and the highlight images drawn from them.
	EnsureAppSwitcherImages()
	Dark := DarkModeEnabled()

	; Lay the items out to fit the monitor the user is actually looking at, and centre the panel
	; there. `Gui.Show` with no X/Y auto-centres on the primary monitor, whereas the real
	; switcher appears wherever the active window is -- and a single row of items ran off the
	; edge of the screen once there were more apps than the display was wide enough for (nine
	; at 1920x150%, twenty-three at 5120x150%).
	;
	; The work area comes back in physical pixels, while `Gui.Show`'s W/H are in DPI-scaled
	; units, so the room available has to be converted before the layout is measured in it.
	WorkArea := AppSwitcherWorkArea(AnchorWindow)
	Layout := AppSwitcherPanelLayout(Apps.Length
		, ScaleToGuiUnits(WorkArea.Width), ScaleToGuiUnits(WorkArea.Height))

	global AppSwitcher := Gui()

	AppSwitcher.SetFont(Format("c{:06X} s{:d}", LabelTextColor(Dark), AppSwitcherStyle.LabelFontSize), "Segoe UI")
	if Dark {
		SetDarkTitle(AppSwitcher)  ; needed for dark window background apparently, even though there's no title bar
	}
	SetDarkMenu()  ; should be unnecessary

	; Windows draws this panel as acrylic when "Transparency effects" is on and as a flat surface
	; colour when it's off -- which is why the reference screenshots show a byte-identical #202020
	; over both a white and a black background. Follow whichever the machine is set to. With the
	; DWM backdrop in play the window has to paint black where the backdrop should show through, so
	; there the panel colour is DWM's to decide rather than ours.
	Acrylic := AppSwitcherPanelIsAcrylic()
	AppSwitcher.BackColor := Acrylic ? 0x000000 : PanelSurfaceColor(Dark)

	; Positions are given explicitly rather than flowed from the margins, because the highlight is
	; larger than the item it surrounds and has to hang outside it.
	AppSwitcher.MarginX := 0
	AppSwitcher.MarginY := 0
	Extent := AppSwitcherStyle.SelectionExtent
	ItemSize := AppSwitcherStyle.ItemSize
	; TODO: get actual size of icon, and allow smaller icons, but not larger than 32 since many programs have 32 as the largest icon size
	; (at least available through WM_GETICON, where you can only request 16x16 or 32x32, so if they provide 32x32, that's what is returned)
	; Or get icon from shortcut file, which could get bigger icons.
	IconSize := AppSwitcherStyle.IconSize
	LabelInset := AppSwitcherStyle.LabelInset
	for index, app in Apps {
		if (index > Layout.ItemsShown) {
			; More apps than the grid can hold. They arrive in recency order, so the ones
			; left out are the least recently used.
			break
		}
		Item := AppSwitcherItemPosition(index, Layout.Columns)
		; The highlight sits behind the icon and the label, and is the control whose image gets
		; swapped as the selection moves. It reaches `Extent` outside the item box on every side,
		; the way Windows' ring reaches outside its cards.
		FocusRingOptions := "x" (Item.X - Extent) " y" (Item.Y - Extent)
			. " w" AppSwitcherStyle.SelectionBoxSize " h" AppSwitcherStyle.SelectionBoxSize
		try {
			FocusRing := AppSwitcher.Add("Pic", FocusRingOptions, AppSwitcherUnselectedImage)
		} catch {
			; Same treatment as the icon below: a Picture control that can't load its image
			; throws "Failed to add control", and losing the highlight is better than losing
			; the switcher. Adding it without an image keeps the layout and the Tab order.
			FocusRing := AppSwitcher.Add("Pic", FocusRingOptions)
		}
		FocusRingByHWND[app.HWND] := FocusRing
		; Icon and label are centred as a single group, so the pair sits in the middle of the item
		; instead of the icon sitting in the middle with the label hanging below it.
		IconX := Item.X + (ItemSize - IconSize) // 2
		IconY := Item.Y + (ItemSize - AppSwitcherStyle.ItemContentHeight) // 2
		LabelY := IconY + IconSize + AppSwitcherStyle.IconToLabelGap
		IconOptions := "x" IconX " y" IconY " w" IconSize " h" IconSize
			. " Tabstop vPicForAppWithHWND" app.HWND
		try {
			AppSwitcher.Add("Pic", IconOptions, "HICON:*" app.Icon)
		} catch {
			; Loading the icon can fail, but I don't know in what cases. It just says "Failed to add control"
			AppSwitcher.Add("Pic", IconOptions, AppSwitcherUnselectedImage)
		}
		LabelOptions := "x" (Item.X + LabelInset) " y" LabelY
			. " w" (ItemSize - 2 * LabelInset) " h" AppSwitcherStyle.LabelHeight
			. " center " SS_WORDELLIPSIS " " SS_NOPREFIX
		AppSwitcher.Add("Text", LabelOptions, app.Title)
	}
	; Belt and braces: this only fires if Escape actually reaches the Gui, which it doesn't
	; while Alt is held (see the Escape hotkey below), i.e. essentially never in practice.
	AppSwitcher.OnEvent("Escape", CancelAppSwitcher)
	AppSwitcher.Opt("+AlwaysOnTop -SysMenu -Caption -Border +Owner")
	; Centre the panel by measuring it rather than predicting it. `Gui.Show` scales W/H by the
	; display DPI but passes X/Y through unscaled (measured: "x100 y100 w200 h200" on a 150%
	; display gives a 300x300 window at physical 100,100), so positioning in the same call
	; would offset the panel by a DPI-dependent amount that grows as the panel gets smaller.
	; Showing it hidden first gives a real window rect in physical pixels, which is the same
	; unit as the work area and as `WinMove`, so nothing has to be scaled at all.
	AppSwitcher.Show("Hide w" Layout.Width " h" Layout.Height)
	WinGetPos(, , &PanelWidth, &PanelHeight, AppSwitcher)
	WinMove(WorkArea.Left + (WorkArea.Width - PanelWidth) // 2
		, WorkArea.Top + (WorkArea.Height - PanelHeight) // 2
		, , , AppSwitcher)
	; W/H/X/Y all omitted, so the window keeps the size and position set above. The warm-up
	; must genuinely be shown -- DWM won't establish composition state for a window that never
	; was -- so NoActivate is as far as it can be toned down: shown, but focus stays put.
	AppSwitcher.Show(Warmup ? "NoActivate" : "")

	; DWM applies these to a window that already exists, and how far the frame is extended
	; depends on the window's final size, so this has to come after `Show`.
	if Acrylic {
		ApplyAppSwitcherFrame(AppSwitcher)
		; Set blur-behind accent effect, matching what the real switcher does when transparency
		; effects are enabled. (Supported starting with Windows 11 Build 22000.)
		; Doesn't seem to work the first time. See workaround below.
		SetDwmWindowAttribute(AppSwitcher.Hwnd, DWMWA_USE_HOSTBACKDROPBRUSH, true)  ; required for DWMSBT_TRANSIENTWINDOW
		SetDwmWindowAttribute(AppSwitcher.Hwnd, DWMWA_SYSTEMBACKDROP_TYPE, DWMSBT_TRANSIENTWINDOW)
	} else {
		ApplyAppSwitcherFrame(AppSwitcher, 1)
	}
}

CloseAppSwitcher(*) {
	global AppSwitcher
	if !AppSwitcher {
		return
	}
	; AppSwitcher.Destroy()
	; AppSwitcher := 0

	; Trying to avoid "Error: Gui has no window." in the compiled script...
	; This might be safer with threading? This way the variable always
	; references an existing window or is 0, right?
	OldAppSwitcher := AppSwitcher
	AppSwitcher := 0
	OldAppSwitcher.Destroy()
}

; Cancel: dismiss the switcher without acting on the highlighted app.
; `CloseAppSwitcher` is only the teardown; this is what makes it a *cancellation*, marking the
; session so that the pending Alt release in the hotkey thread commits nothing.
CancelAppSwitcher(*) {
	global AppSwitcherCancelled := true
	CloseAppSwitcher()
}

; Confirm: activate whatever is highlighted, then dismiss the switcher.
; This is the only path that activates an application.
ConfirmAppSwitcher() {
	global AppSwitcher, AppSwitcherCancelled
	; Read the global once: the Escape hotkey can zero it between the check below and the
	; use after it, which would make that use throw.
	Switcher := AppSwitcher
	; Don't commit a cancelled session. Also don't commit a switcher that's already gone, which
	; happens when a newer Alt+Tab session has opened and closed one in the meantime; between
	; them, a stale hotkey thread can never activate anything.
	if (!Switcher || AppSwitcherCancelled) {
		return
	}
	; Normally `AppSwitcher.FocusedCtrl` exists at this point,
	; but it may not exist if focus changes while the switcher is open
	; such as by pressing Win+D to show the desktop, then releasing Win.
	SelectedPic := Switcher.FocusedCtrl
	SelectedHWND := 0
	if SelectedPic {
		Parts := StrSplit(SelectedPic.Name, "PicForAppWithHWND")
		if (Parts.Length >= 2 && IsInteger(Parts[2])) {
			SelectedHWND := Integer(Parts[2])
		}
	}
	CloseAppSwitcher()
	if SelectedHWND {
		try {
			WinActivate(SelectedHWND)
		} catch {
			; The window was captured when the panel was built and can have closed while the
			; user held Alt -- a dialog that dismissed itself, an app that crashed. Throwing
			; here would put an error box up at the exact moment they let go of Alt, which is
			; a worse outcome than the switch quietly not happening.
		}
	}
}

; Workaround for blur-behind accent effect not working the first time the app switcher is shown.
; FIXME: the effect is still not reliably applied. This helps, but it doesn't get at the root cause.
; Hm, resizing a test window seems to make the effect work. Maybe I can trigger something like a resize event to make it work reliably.
; Or many such events? Since it updates gradually? (Is it an animation, or is it updating only slightly at a given event?)
ShowAppSwitcher([], 0, true)  ; shown but not activated, so it doesn't steal focus at startup
CloseAppSwitcher()


LastFocusHighlight := 0
UpdateFocusHighlight() {
	global LastFocusHighlight
	; Read the global once, rather than dereferencing it repeatedly. `CancelAppSwitcher`
	; zeroes it from the Escape hotkey's thread, and that thread can interrupt the
	; `Send "{Tab}"` immediately before each of this function's two call sites -- at which
	; point `AppSwitcher.FocusedCtrl` is `0.FocusedCtrl`, an unhandled exception, and an
	; error dialog on top of the switcher the user is still holding Alt for.
	Switcher := AppSwitcher
	if LastFocusHighlight {
		try {
			LastFocusHighlight.Value := AppSwitcherUnselectedImage
		} catch {
			; App switcher closed and destroyed the control
		}
	}
	if !Switcher {
		; Cancelled out from under us. The control we just unhighlighted belongs to a Gui
		; that no longer exists, so forget it rather than reaching for it again next time.
		LastFocusHighlight := 0
		return
	}
	Pic := Switcher.FocusedCtrl
	if !Pic {
		; Probably shouldn't happen, GENERALLY, with logic outside this function focusing the app switcher if it's not focused
		; but maybe it could lose focus immediately after being focused with `WinActivate`,
		; or immedaitely after showing the app switcher.
		return
	}
	; Only the icon pics are named, and only they are tabstops, so this normally always
	; resolves. But a focused control left over from a session that has already been torn
	; down would parse to a key the map no longer holds, and an unguarded `Map` lookup
	; throws -- so take the same view of it as of everything else here: if the answer isn't
	; there, leave the highlight alone rather than failing loudly mid-keypress.
	Parts := StrSplit(Pic.Name, "PicForAppWithHWND")
	if (Parts.Length < 2 || !IsInteger(Parts[2])) {
		return
	}
	Key := Integer(Parts[2])
	if !FocusRingByHWND.Has(Key) {
		return
	}
	FocusRing := FocusRingByHWND[Key]
	try {
		; `AppSwitcherSelectedImage` is "" if the highlight images couldn't be written at
		; all -- see `EnsureAppSwitcherImages` -- and assigning that to a Picture throws.
		FocusRing.Value := AppSwitcherSelectedImage
	} catch {
		return
	}
	LastFocusHighlight := FocusRing
}

; The `$` prefix forces these to be implemented with the keyboard hook, which is what
; makes it possible to take Alt+Tab away from Windows at all -- and it's also what makes
; them ignore the synthetic Alt+Tab that window-switcher.ahk sends to open the *native*
; task switcher. See the coordination notes in logical-app.ahk.
$!Tab::
$!+Tab:: {
	global AppSwitcher
	if IsNativeSwitcherSessionActive() {
		; The same-app window switcher currently has the native task switcher open.
		; Pass Tab through so that it cycles through that, instead of opening this
		; switcher on top of it. Sent at the default send level, so this doesn't come
		; straight back to this hotkey.
		Send "{Blind}{Tab}"
		return
	}
	if AppSwitcher {
		; Cycle through apps in the app switcher
		; This uses normal control tabbing behavior, so it requires the app switcher to be focused.

		; Normally `AppSwitcher.FocusedCtrl` exists at this point,
		; but it may not exist if focus changes while the switcher is open
		; such as by pressing Win+D to show the desktop,
		; then pressing Tab while Win is still held down.
		if !AppSwitcher.FocusedCtrl {
			; Focus the app switcher so that it will have a focused control again.
			; Do this before sending Tab so that it still cycles even in this case.
			WinActivate(AppSwitcher.HWND)
		}
		if GetKeyState("Shift") {
			Send "+{Tab}"
		} else {
			Send "{Tab}"
		}
		UpdateFocusHighlight()
		return
	}
	; Group windows by logical application rather than by process path, so that Chrome
	; and each of its installed PWAs are separate entries, while all of Chrome's own
	; windows collapse into one. GetLogicalAppId prefers the window's AUMID (which is
	; what the taskbar groups by) and falls back to the process path.
	ClearLogicalAppCache()

	; The window that was active before the switcher opens, so the panel can be placed on the
	; monitor the user is looking at. Captured up front, because showing the panel takes the
	; foreground away.
	AnchorWindow := WinExist("A")

	; `WinGetList` returns windows "in order from topmost to bottommost", so the first window
	; seen for an application is that application's topmost one, and the applications come out
	; in z-order -- which is the recency order the switcher wants. This used to be
	; reconstructed after the fact with window groups and an insertion sort, which cost O(N^2)
	; whole-desktop enumerations per keypress and leaked a window group per comparison.
	TopWindows := []
	SeenAppIds := Map()
	for Window in WinGetList() {
		AppId := ""
		try {
			if Switchable(Window) {
				AppId := GetLogicalAppId(Window)
			}
		} catch {
			; The window may have been destroyed while we were enumerating.
		}
		if (AppId = "" || SeenAppIds.Has(AppId)) {
			continue
		}
		SeenAppIds[AppId] := true
		TopWindows.Push(Window)
	}

	Apps := []
	for Window in TopWindows {
		IconHandle := GetLogicalAppIconHandle(Window)
		if (!IconHandle) {
			; An application the user can see on screen has to appear in the switcher, so a
			; placeholder stands in rather than the entry being dropped. Nothing is expected
			; to reach this now that packaged apps resolve through the AppsFolder, but an
			; application silently missing from Alt+Tab is a hard bug to even notice, let
			; alone diagnose, and a generic icon makes it obvious instead.
			IconHandle := GenericAppIconHandle()
		}
		Apps.Push({
			Icon: IconHandle,
			Title: GetLogicalAppDisplayName(Window),
			HWND: Window,
		})
	}
	if (Apps.Length < 2) {
		; Nothing to switch between, so don't put a panel up at all -- window-switcher.ahk
		; takes the same shortcut. Note that the hook hotkey swallows the keystroke either
		; way, so returning here means Alt+Tab does nothing at all.
		return
	}
	ShowAppSwitcher(Apps, AnchorWindow)
	; Initially select the next app after the currently focused app when opening the switcher.
	; (Otherwise you always have to press Tab twice to get to the next app.)
	if GetKeyState("Shift") {
		Send "+{Tab}"
	} else {
		Send "{Tab}"
	}
	UpdateFocusHighlight()
	; Wait for Alt to be released, which is what commits the selection.
	; It matters that this is the *physical* state, which is what KeyWait waits on by default:
	; `Send` above temporarily lifts whichever modifier the user is holding so that it can send
	; a bare Tab, so the *logical* Alt state briefly looks released while tabbing through the
	; switcher. (KeyWait's only options are D, L and T -- there is no "P" to ask for explicitly.)
	if GetKeyState("LAlt", "P") {
		KeyWait "LAlt"
	} else if GetKeyState("RAlt", "P") { ; just to be sure we don't wait forever in case the key was released quickly
		KeyWait "RAlt"
	}
	; Releasing Alt is what confirms the selection. The switcher is normally still open at this
	; point, but it may have been cancelled with Escape, in which case this does nothing.
	ConfirmAppSwitcher()
}

; Escape cancels the app switcher, and nothing else.
; The `$` prefix forces this to be implemented with the keyboard hook, which is what lets it
; take the keystroke away from Windows. Without it, Alt+Esc -- and Escape is only ever pressed
; with Alt held here, since holding Alt is what keeps the switcher open -- is swallowed by the
; OS as its own "activate the next window in the z-order" shortcut, which switches apps behind
; our back and stops the Gui's Escape event from ever firing.
; `*` matches whatever modifiers are held (Alt, plus Shift when cycling backwards).
; The Alt release is deliberately not consumed: the `KeyWait` above still returns as usual,
; it just finds the session cancelled and commits nothing.
#HotIf AppSwitcher
$*Escape:: {
	CancelAppSwitcher()
}
#HotIf

;--------------------------------------------------------
; AUTO RELOAD THIS SCRIPT
;--------------------------------------------------------
~^s:: {
	if WinActive(A_ScriptName) {
		MakeSplash("AHK Auto-Reload", "`n  Reloading " A_ScriptName "  `n", 500)
		Reload
	}
}
