#Requires AutoHotkey v2.0

;--------------------------------------------------------
; Logical Application Identity
;--------------------------------------------------------
; Shared by app-switcher.ahk and window-switcher.ahk.
;
; A "logical application" is what a user thinks of as one app, and what the taskbar
; groups windows by. It is NOT the same thing as a process:
;
; - 10 Chrome browser windows are one logical app, even though Chrome spreads them
;   across several processes.
; - Chrome, the "Google Chat" PWA and the "Google Meet" PWA are three logical apps,
;   even though all of them run under chrome.exe.
;
; Windows already has an identity for this concept: the Application User Model ID
; (AUMID). Apps set it per-window through SHGetPropertyStoreForWindow +
; System.AppUserModel.ID, and it is exactly what the taskbar uses to decide which
; windows share a taskbar button. Chromium sets it per browser window and gives every
; installed PWA its own AUMID, so identifying apps by AUMID separates PWAs generically,
; with no browser-specific rules. (Measured on Chrome: normal windows report "Chrome",
; the Google Chat PWA reports "Chrome._crx_pommaclcbflboakcipcmmndhcj", and the Google
; Meet PWA reports "Chrome._crx_kjgfgldnnffkjfagphfepbbdan".)
;
; Windows that don't expose an AUMID fall back to their executable path, which is what
; the app switcher used for everything before.
;
; Identity hierarchy:
;   1. "aumid:<System.AppUserModel.ID of the window>"
;   2. "exe:<lowercased full path of the owning process>"
;
; See GetLogicalAppDisplayName / GetLogicalAppIconHandle for the display metadata
; hierarchies, which look past the executable (whose version info says "Google Chrome"
; for every PWA) to the app model metadata and Start Menu shortcuts.

;--------------------------------------------------------
; Windows API constants
;--------------------------------------------------------

WM_GETICON := 0x007F

ICON_BIG := 1
ICON_SMALL := 0
ICON_SMALL2 := 2

GCLP_HICON := -14 ; Retrieves a handle to the icon associated with the class.
GCLP_HICONSM := -34 ; Retrieves a handle to the small icon associated with the class.

WS_CHILD := 0x40000000
; WS_THICKFRAME := 0x00040000
; WS_POPUP := 0x80000000
; WS_CLIPCHILDREN := 0x02000000

WS_EX_APPWINDOW := 0x00040000
WS_EX_TOOLWINDOW := 0x00000080

; PROPERTYKEYs from the App User Model property set.
; https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-id
PKEY_AppUserModel_FMTID := "{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}"
PID_AppUserModel_ID := 5 ; System.AppUserModel.ID
PID_AppUserModel_RelaunchIconResource := 3 ; System.AppUserModel.RelaunchIconResource
PID_AppUserModel_RelaunchDisplayNameResource := 4 ; System.AppUserModel.RelaunchDisplayNameResource

; PROPERTYKEYs from the version-resource property set. The shell surfaces an
; executable's version info as ordinary properties, which saves reading the version
; resource by hand. (Measured: chrome.exe -> FileDescription "Google Chrome".)
; https://learn.microsoft.com/en-us/windows/win32/properties/props-system-filedescription
PKEY_Version_FMTID := "{0CEF7D53-FA64-11D1-A203-0000F81FEDEE}"
PID_FileDescription := 3 ; System.FileDescription
PID_ProductName := 7 ; System.Software.ProductName

; VARENUM members that a string-valued PROPVARIANT can use.
VT_BSTR := 8
VT_LPWSTR := 31

; IPropertyStore::GetValue is the 6th vtable entry (0-based index 5), after
; QueryInterface/AddRef/Release and GetCount/GetAt.
IID_IPropertyStore := "{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}"
IPropertyStore_GetValue := 5

; IShellItem::GetDisplayName is the 6th vtable entry, after IUnknown's three and
; BindToHandler/GetParent. IShellItemImageFactory::GetImage is the first entry of its own,
; the interface having no other methods.
IID_IShellItem := "{43826D1E-E718-42EE-BC55-A1E261C37BFE}"
IShellItem_GetDisplayName := 5
IID_IShellItemImageFactory := "{BCC18B79-BA16-442F-80C4-8A59C30C463B}"
IShellItemImageFactory_GetImage := 3

; SIGDN_NORMALDISPLAY asks for the name as the shell would show it ("Microsoft Store"),
; rather than a parsing name. SIIGBF_ICONONLY forbids substituting a document thumbnail for
; the app's icon; notably SIIGBF_BIGGERSIZEOK is *not* passed, so the shell returns exactly
; the size asked for rather than whatever larger asset it happens to hold.
SIGDN_NORMALDISPLAY := 0
SIIGBF_ICONONLY := 0x4

; The system's stock "some application" icon, used when every other source comes up empty.
IDI_APPLICATION := 32512

; DWM hides some windows without clearing WS_VISIBLE. See IsWindowCloaked.
DWMWA_CLOAKED := 14

; The shell's application views.
;
; Windows 11 does not decide what goes in Alt+Tab by enumerating windows and applying the
; classic style rules -- it iterates the shell's IApplicationView objects. That is why
; ITaskbarList::DeleteTab, WS_EX_TOOLWINDOW and DWMWA_CLOAK all fail to hide a UWP window:
; every one of them acts on the HWND, which the immersive path never consults. Measured on
; Windows 11 against live Settings and Microsoft Store windows -- DeleteTab returns S_OK and
; changes nothing, WS_EX_TOOLWINDOW applies to the frame and changes nothing (with or
; without a hide/show cycle to force re-evaluation), and DwmSetWindowAttribute(DWMWA_CLOAK)
; fails outright with E_ACCESSDENIED.
;
; Each view carries a "show in switchers" flag, the undocumented twin of
; AppWindow.IsShownInSwitchers, which Microsoft documents as controlling whether a window
; "will appear in various system representations, such as ALT+TAB and taskbar". It can be
; set for another process's window through the immersive shell -- the same route every
; virtual desktop tool uses to move other applications' windows between desktops.
;
; These interfaces are undocumented, so the vtable slots are the load-bearing part. They
; match the declarations shared by the established virtual-desktop projects, and both
; accessors are confirmed by measurement: reading slot 27 for a Settings window returns 1,
; and writing 0 to slot 28 reads back as 0.
CLSID_ImmersiveShell := "{C2F03A33-21F5-47FA-B4BB-156362A2F239}"
IID_IServiceProvider := "{6D5140C1-7436-11CE-8034-00AA006009FA}"
IID_IApplicationViewCollection := "{1841C6D7-4F9D-42C0-AF41-8747538F10E5}"
IServiceProvider_QueryService := 3
IApplicationViewCollection_GetViewForHwnd := 6
IApplicationView_GetShowInSwitchers := 27
IApplicationView_SetShowInSwitchers := 28

; A UWP app's frame window, which is the only kind that needs the view treatment above.
UWP_FRAME_WINDOW_CLASS := "ApplicationFrameWindow"

; GETPROPERTYSTOREFLAGS
GPS_DEFAULT := 0

; A PROPVARIANT is 16 bytes when built for 32-bit and 24 bytes when built for 64-bit.
; In both cases the union (where the string pointer lives) starts at offset 8, after
; `vt` and three reserved WORDs.
PROPVARIANT_SIZE := A_PtrSize = 8 ? 24 : 16
PROPVARIANT_VALUE_OFFSET := 8

; Make sure COM is available on this thread before calling into the shell.
; CoInitialize is reference counted, so this is harmless if AutoHotkey (or another
; included library) already initialized COM. We deliberately never call
; CoUninitialize, since COM should stay available for the life of the script.
DllCall("ole32\CoInitialize", "ptr", 0)

;--------------------------------------------------------
; Logical application identity
;--------------------------------------------------------

; Per-window memoization, so that enumerating every window on screen doesn't repeat the
; same shell calls. Cleared by ClearLogicalAppCache at the start of each switcher
; invocation, so a recycled HWND can never return stale data.
LogicalAppIdCache := Map()
LogicalAppNameCache := Map()

; Keyed by icon resource string rather than by window, and deliberately never cleared:
; the icons we extract ourselves are HICONs we own, and caching them means opening the
; switcher repeatedly can't leak a handle per keypress.
LogicalAppIconCache := Map()

; Executable display names, keyed by path and never cleared: an executable's version info
; doesn't change while it's running, so this turns the shell bind above into a one-off per
; application rather than a cost paid on every Alt+Tab.
ExecutableDisplayNameCache := Map()
ExecutableDisplayNameCache.CaseSense := false ; paths are case-insensitive on Windows

; Shortcut icons, keyed by shortcut path for the same reason. Keying these outside the
; shortcut index matters: BuildAppShortcutIndex replaces every entry object, so an icon
; cached on the entry itself would be orphaned -- leaked, since nothing calls DestroyIcon
; on it -- every time the index is rebuilt.
ShortcutIconCache := Map()

; AppsFolder names and icons, keyed by AUMID and never cleared. Binding a shell item costs
; about as much as binding a property store, and this tier is only reached by applications
; that have nothing else to offer, so caching turns it into a one-off per application. As
; with the caches above, a cached "" or 0 records "asked, and there is nothing", which is
; worth remembering too. The icons are HICONs we created, and therefore ours.
AppsFolderNameCache := Map()
AppsFolderNameCache.CaseSense := false ; AUMIDs are compared case-insensitively by the shell
AppsFolderIconCache := Map()
AppsFolderIconCache.CaseSense := false

ClearLogicalAppCache() {
	LogicalAppIdCache.Clear()
	LogicalAppNameCache.Clear()
}

; Returns a string identifying the logical application a window belongs to, or "" if
; the window couldn't be identified at all (e.g. it was destroyed while enumerating).
; IDs are only ever compared to each other, never parsed by callers.
GetLogicalAppId(Window) {
	if !Window {
		return ""
	}
	if LogicalAppIdCache.Has(Window) {
		return LogicalAppIdCache[Window]
	}
	AppId := ""
	AppUserModelId := GetWindowAppUserModelId(Window)
	if (AppUserModelId != "") {
		; Used verbatim, including any Chrome profile suffix. Chromium derives distinct
		; AUMIDs per profile, so windows from two Chrome profiles count as two logical
		; apps -- which is also how the taskbar groups them. Stripping the profile out
		; would second-guess Windows' own notion of application identity.
		AppId := "aumid:" AppUserModelId
	} else {
		try {
			ProcessPath := WinGetProcessPath(Window)
		} catch {
			; Can fail for windows we aren't allowed to query, or ones that just closed.
			ProcessPath := ""
		}
		if (ProcessPath != "") {
			; Paths are case-insensitive on Windows, so normalize them for comparison.
			AppId := "exe:" StrLower(ProcessPath)
		}
	}
	LogicalAppIdCache[Window] := AppId
	return AppId
}

; Returns the System.AppUserModel.ID of a top-level window, or "" if it has none.
GetWindowAppUserModelId(Window) {
	return GetWindowAppModelProperty(Window, PID_AppUserModel_ID)
}

; Same as GetWindowAppUserModelId, but reuses GetLogicalAppId's cache instead of making
; another shell call.
GetCachedWindowAppUserModelId(Window) {
	AppId := GetLogicalAppId(Window)
	return SubStr(AppId, 1, 6) = "aumid:" ? SubStr(AppId, 7) : ""
}

GetWindowAppModelProperty(Window, PropertyId) {
	return GetWindowShellProperty(Window, PKEY_AppUserModel_FMTID, PropertyId)
}

; Reads a single string property from a window's property store, using the same API the
; taskbar uses. Returns "" if the window has no property store, doesn't set the
; property, or sets it to something that isn't a string.
GetWindowShellProperty(Window, FormatId, PropertyId) {
	if !Window {
		return ""
	}
	InterfaceId := Buffer(16, 0)
	if (DllCall("ole32\CLSIDFromString", "wstr", IID_IPropertyStore, "ptr", InterfaceId, "int") != 0) {
		return ""
	}
	PropertyStore := 0
	try {
		HResult := DllCall("shell32\SHGetPropertyStoreForWindow", "ptr", Window, "ptr", InterfaceId, "ptr*", &PropertyStore, "int")
	} catch {
		; SHGetPropertyStoreForWindow exists on Windows 7 and later, so this shouldn't
		; happen, but a missing export must not take down the switcher.
		return ""
	}
	if (HResult != 0 || !PropertyStore) {
		; Common and expected: this fails for elevated windows when we aren't elevated,
		; and for windows that were destroyed while we were enumerating.
		return ""
	}
	return ReadStringPropertyAndRelease(PropertyStore, FormatId, PropertyId)
}

; Same, for a file: reads properties from one property store, returning the first non-empty
; value. Used to read the AUMID that Start Menu shortcuts advertise, and an executable's
; version info.
;
; Binding the store is the expensive part -- measured at 6+ ms per bind on a local
; executable -- and this runs on the interactive Alt+Tab path, once per application without
; an AUMID. So properties that are alternatives to one another are read in a single call
; rather than one call each.
GetFirstFileShellProperty(Path, FormatId, PropertyIds*) {
	if (Path = "") {
		return ""
	}
	InterfaceId := Buffer(16, 0)
	if (DllCall("ole32\CLSIDFromString", "wstr", IID_IPropertyStore, "ptr", InterfaceId, "int") != 0) {
		return ""
	}
	PropertyStore := 0
	try {
		HResult := DllCall("shell32\SHGetPropertyStoreFromParsingName", "wstr", Path, "ptr", 0, "uint", GPS_DEFAULT, "ptr", InterfaceId, "ptr*", &PropertyStore, "int")
	} catch {
		return ""
	}
	if (HResult != 0 || !PropertyStore) {
		return ""
	}
	try {
		for PropertyId in PropertyIds {
			Value := ReadStringProperty(PropertyStore, FormatId, PropertyId)
			if (Value != "") {
				return Value
			}
		}
	} finally {
		ObjRelease(PropertyStore)
	}
	return ""
}

; Takes ownership of PropertyStore: releases it before returning, however it returns.
ReadStringPropertyAndRelease(PropertyStore, FormatId, PropertyId) {
	try {
		return ReadStringProperty(PropertyStore, FormatId, PropertyId)
	} finally {
		ObjRelease(PropertyStore)
	}
}

; Leaves PropertyStore alone -- the caller owns it.
ReadStringProperty(PropertyStore, FormatId, PropertyId) {
	PropVariant := Buffer(PROPVARIANT_SIZE, 0)
	Value := ""
	try {
		PropertyKey := Buffer(20, 0) ; struct PROPERTYKEY { GUID fmtid; DWORD pid; }
		if (DllCall("ole32\CLSIDFromString", "wstr", FormatId, "ptr", PropertyKey, "int") = 0) {
			NumPut("uint", PropertyId, PropertyKey, 16)
			; Asking for an "int" return rather than the default HRESULT return type makes
			; a failure a value to check instead of an exception to unwind.
			if (ComCall(IPropertyStore_GetValue, PropertyStore, "ptr", PropertyKey, "ptr", PropVariant, "int") = 0) {
				VariantType := NumGet(PropVariant, 0, "ushort")
				if (VariantType = VT_LPWSTR || VariantType = VT_BSTR) {
					StringPointer := NumGet(PropVariant, PROPVARIANT_VALUE_OFFSET, "ptr")
					if StringPointer {
						Value := StrGet(StringPointer, "UTF-16")
					}
				}
			}
		}
	} catch {
		Value := ""
	} finally {
		; PropVariantClear is safe on a zeroed PROPVARIANT (VT_EMPTY), so it's correct to
		; call unconditionally, including when GetValue failed.
		DllCall("ole32\PropVariantClear", "ptr", PropVariant)
	}
	return Value
}

;--------------------------------------------------------
; AUMID -> shortcut index
;--------------------------------------------------------
; Installed PWAs expose a distinct AUMID per app, but (measured on Chrome) their
; windows do NOT set System.AppUserModel.RelaunchDisplayNameResource or
; RelaunchIconResource, so there's nothing on the window itself to name them by --
; every PWA would show up as "Google Chrome", with Chrome's icon.
;
; Start Menu and pinned shortcuts do carry the AUMID, though, and that's how the
; taskbar names and pins them. So we index shortcuts by AUMID and use the matching
; shortcut's name and icon. This is generic: it works for Chrome PWAs, Edge PWAs, and
; anything else that ships a shortcut with an AUMID.
;
; The scan costs on the order of a second (roughly 7 ms per shortcut, dominated by the
; shell binding each one), so it's done at most once every RescanIntervalMs, and
; app-switcher.ahk primes it on a timer shortly after startup so that the first
; Alt+Tab isn't the one that pays for it.

ShortcutIndexByAppUserModelId := 0
ShortcutIndexBuildTickCount := 0

; Builds the index up front, so an interactive switcher invocation doesn't have to.
PrimeAppShortcutIndex() {
	if !ShortcutIndexByAppUserModelId {
		BuildAppShortcutIndex()
	}
}

; Returns { Name, Path } for the shortcut advertising this AUMID, or 0.
FindShortcutForAppUserModelId(AppUserModelId) {
	static RescanIntervalMs := 300000 ; 5 minutes
	if (AppUserModelId = "") {
		return 0
	}
	global ShortcutIndexBuildTickCount
	if !ShortcutIndexByAppUserModelId {
		; Cold start only, and `PrimeAppShortcutIndex` normally gets here first. Paid
		; inline because the alternative is a first switcher with no PWA names in it.
		BuildAppShortcutIndex()
	}
	; Read the index once. A rebuild replaces the whole Map, and now that rebuilds happen
	; on a timer thread rather than this one, `Has` and `[...]` against the global could
	; otherwise land on either side of the swap.
	Index := ShortcutIndexByAppUserModelId
	if Index.Has(AppUserModelId) {
		return Index[AppUserModelId]
	}
	; A shortcut may have appeared since the index was built, e.g. by installing a new PWA.
	; Rebuild for that case, rate limited, since scanning isn't cheap -- and *off* this
	; thread, because "isn't cheap" means about a second, and this runs on the interactive
	; Alt+Tab path with the panel not yet on screen. An AUMID that matches no shortcut is
	; the ordinary case for packaged apps, so before this the first Alt+Tab after any five
	; minute lull paid for a full rescan.
	;
	; The cost of deferring is that a newly installed app is named on the *next* Alt+Tab
	; rather than this one, which is a better trade than a one second stall every time.
	; (The A_TickCount comparison also handles its ~49 day wraparound.)
	Age := A_TickCount - ShortcutIndexBuildTickCount
	if (Age > RescanIntervalMs || Age < 0) {
		; Claim the interval up front, so a switcher listing several unrecognized AUMIDs
		; schedules one rescan rather than one per app. `BuildAppShortcutIndex` sets it
		; again when it finishes.
		;
		; A negative period is only "after 1 ms" -- what keeps the scan off this thread is
		; the `Thread "NoTimers"` in app-switcher.ahk's Alt+Tab handler, which holds every
		; timer back until the keypress is over. Without that, this fires mid-loop and the
		; stall is merely relocated.
		ShortcutIndexBuildTickCount := A_TickCount
		SetTimer(BuildAppShortcutIndex, -1)
	}
	return 0
}

BuildAppShortcutIndex() {
	global ShortcutIndexByAppUserModelId, ShortcutIndexBuildTickCount
	Index := Map()
	Index.CaseSense := false ; AUMIDs are compared case-insensitively by the shell
	for Folder in AppShortcutSearchFolders() {
		if (Folder = "" || !DirExist(Folder)) {
			continue
		}
		Loop Files Folder "\*.lnk", "FR" {
			AppUserModelId := GetFirstFileShellProperty(A_LoopFileFullPath, PKEY_AppUserModel_FMTID, PID_AppUserModel_ID)
			if (AppUserModelId = "" || Index.Has(AppUserModelId)) {
				; First shortcut found for an AUMID wins; the search folders are ordered
				; most-specific-first so that a pinned shortcut beats a Start Menu one.
				continue
			}
			SplitPath(A_LoopFileFullPath, , , , &NameWithoutExtension)
			Index[AppUserModelId] := {
				Name: NormalizeAppDisplayName(NameWithoutExtension),
				Path: A_LoopFileFullPath,
			}
		}
	}
	ShortcutIndexByAppUserModelId := Index
	ShortcutIndexBuildTickCount := A_TickCount
}

AppShortcutSearchFolders() {
	QuickLaunch := A_AppData "\Microsoft\Internet Explorer\Quick Launch\User Pinned"
	return [
		; Pinned taskbar buttons, and the shortcuts Windows generates automatically for
		; windows it sees with an AUMID. These are the most likely to be named the way
		; the user sees the app named.
		QuickLaunch "\TaskBar",
		QuickLaunch "\ImplicitAppShortcuts",
		; The Start Menu, which is where installers and Chrome/Edge put app shortcuts
		; (Chrome PWAs land in "Programs\Chrome Apps").
		A_StartMenu,
		A_StartMenuCommon,
	]
}

; Windows uniquifies names by appending " (1)", " (2)" and so on when two would otherwise
; collide, and it does this in both places an app's name can come from: a PWA's shortcut can
; be called "Google Chat (1).lnk", and the same app's AppsFolder entry is likewise named
; "Google Chat (1)" (measured). Drop that suffix so the switcher shows "Google Chat".
NormalizeAppDisplayName(Name) {
	if RegExMatch(Name, "^(.*\S)\s+\(\d+\)$", &Match) {
		return Match[1]
	}
	return Name
}

;--------------------------------------------------------
; AUMID -> AppsFolder
;--------------------------------------------------------
; "shell:AppsFolder" is the virtual folder behind the Start Menu's app list, and it is the
; only place a packaged (UWP/Store) application's name and icon exist: such an app has no
; shortcut on disk for the index above to find, and the executable hosting its window is
; ApplicationFrameHost.exe, which carries no icon resources and no useful version info. It
; answers for ordinary applications and PWAs too, but those are already served by the tiers
; ahead of it, so in practice this is the packaged-app tier.
;
; Measured: "Microsoft.WindowsStore_8wekyb3d8bbwe!App" -> "Microsoft Store" plus a 32x32
; 32-bit icon, and an AUMID naming nothing installed fails cleanly with ERROR_FILE_NOT_FOUND.

; The size the app switcher draws icons at. Asking the shell for exactly this saves
; rescaling a larger asset by hand.
APPS_FOLDER_ICON_SIZE := 32

; Returns the name the shell gives an AUMID in the AppsFolder, or "".
GetAppsFolderDisplayName(AppUserModelId) {
	if (AppUserModelId = "") {
		return ""
	}
	if AppsFolderNameCache.Has(AppUserModelId) {
		return AppsFolderNameCache[AppUserModelId]
	}
	Name := ""
	ShellItem := BindAppsFolderItem(AppUserModelId, IID_IShellItem)
	if ShellItem {
		try {
			StringPointer := 0
			if (ComCall(IShellItem_GetDisplayName, ShellItem, "uint", SIGDN_NORMALDISPLAY, "ptr*", &StringPointer, "int") = 0 && StringPointer) {
				Name := NormalizeAppDisplayName(StrGet(StringPointer, "UTF-16"))
				DllCall("ole32\CoTaskMemFree", "ptr", StringPointer)
			}
		} catch {
			Name := ""
		} finally {
			ObjRelease(ShellItem)
		}
	}
	AppsFolderNameCache[AppUserModelId] := Name
	return Name
}

; Returns an HICON for an AUMID's AppsFolder entry, or 0. The handle is ours, and is cached
; rather than destroyed, so that repeatedly opening the switcher can't leak one.
GetAppsFolderIconHandle(AppUserModelId) {
	if (AppUserModelId = "") {
		return 0
	}
	if AppsFolderIconCache.Has(AppUserModelId) {
		return AppsFolderIconCache[AppUserModelId]
	}
	IconHandle := 0
	ImageFactory := BindAppsFolderItem(AppUserModelId, IID_IShellItemImageFactory)
	if ImageFactory {
		try {
			Bitmap := 0
			; GetImage takes its SIZE *by value*, and an 8-byte struct is passed the same way
			; a 64-bit integer is on both architectures, so packing the two LONGs into one is
			; the whole of the marshalling.
			PackedSize := (APPS_FOLDER_ICON_SIZE << 32) | APPS_FOLDER_ICON_SIZE
			if (ComCall(IShellItemImageFactory_GetImage, ImageFactory, "int64", PackedSize, "uint", SIIGBF_ICONONLY, "ptr*", &Bitmap, "int") = 0 && Bitmap) {
				IconHandle := IconFromBitmap(Bitmap)
				DllCall("gdi32\DeleteObject", "ptr", Bitmap)
			}
		} catch {
			IconHandle := 0
		} finally {
			ObjRelease(ImageFactory)
		}
	}
	AppsFolderIconCache[AppUserModelId] := IconHandle
	return IconHandle
}

; Binds one AppsFolder entry to the requested interface, or returns 0.
BindAppsFolderItem(AppUserModelId, InterfaceId) {
	InterfaceGuid := Buffer(16, 0)
	if (DllCall("ole32\CLSIDFromString", "wstr", InterfaceId, "ptr", InterfaceGuid, "int") != 0) {
		return 0
	}
	ShellItem := 0
	try {
		; Asking for an "int" return rather than the default HRESULT return type makes the
		; common failure -- an AUMID that names no installed application -- a value to check
		; instead of an exception to unwind.
		HResult := DllCall("shell32\SHCreateItemFromParsingName", "wstr", "shell:AppsFolder\" AppUserModelId, "ptr", 0, "ptr", InterfaceGuid, "ptr*", &ShellItem, "int")
	} catch {
		return 0
	}
	return (HResult = 0) ? ShellItem : 0
}

; Converts an HBITMAP into an HICON, so that the AppsFolder tier hands back the same kind of
; handle as every other tier and the panel's picture controls don't have to care where an
; icon came from. Returns 0 on failure. The bitmap stays the caller's to delete.
IconFromBitmap(Bitmap) {
	; BITMAP { LONG bmType; LONG bmWidth; LONG bmHeight; LONG bmWidthBytes;
	;          WORD bmPlanes; WORD bmBitsPixel; LPVOID bmBits; }
	BitmapInfo := Buffer(A_PtrSize = 8 ? 32 : 24, 0)
	if !DllCall("gdi32\GetObjectW", "ptr", Bitmap, "int", BitmapInfo.Size, "ptr", BitmapInfo) {
		return 0
	}
	Width := NumGet(BitmapInfo, 4, "int")
	Height := NumGet(BitmapInfo, 8, "int")
	; CreateIconIndirect wants a mask even for a bitmap that carries its own alpha channel.
	; A freshly created monochrome bitmap is all zeroes, which means "opaque everywhere" and
	; leaves the alpha to do the work.
	Mask := DllCall("gdi32\CreateBitmap", "int", Width, "int", Height, "uint", 1, "uint", 1, "ptr", 0, "ptr")
	if !Mask {
		return 0
	}
	; ICONINFO { BOOL fIcon; DWORD xHotspot; DWORD yHotspot; HBITMAP hbmMask; HBITMAP hbmColor; }
	; The two handles are pointer-aligned, so on 64-bit they sit past four bytes of padding.
	IconInfo := Buffer(A_PtrSize = 8 ? 32 : 20, 0)
	NumPut("int", 1, IconInfo, 0)
	NumPut("ptr", Mask, IconInfo, A_PtrSize = 8 ? 16 : 12)
	NumPut("ptr", Bitmap, IconInfo, A_PtrSize = 8 ? 24 : 16)
	; CreateIconIndirect copies both bitmaps rather than taking ownership of them, so the mask
	; is ours to delete as soon as it returns.
	IconHandle := DllCall("user32\CreateIconIndirect", "ptr", IconInfo, "ptr")
	DllCall("gdi32\DeleteObject", "ptr", Mask)
	return IconHandle
}

;--------------------------------------------------------
; Logical application display metadata
;--------------------------------------------------------

; Returns a human-readable name for the logical application a window belongs to.
;
; Hierarchy:
;   1. System.AppUserModel.RelaunchDisplayNameResource on the window (how app model
;      windows announce their own name, e.g. Chrome reports "Google Chrome")
;   2. The name of the Start Menu / pinned shortcut with the same AUMID (this is what
;      names installed PWAs, e.g. "Google Chat", "Google Meet")
;   3. The name of the AUMID's AppsFolder entry (this is what names packaged apps, e.g.
;      "Settings", "Microsoft Store", which have no shortcut on disk)
;   4. The executable's FileDescription, then its ProductName
;   5. The window title
;   6. The executable's filename, without the extension
;
; Note that the executable's version info is preferred over the window title even
; though the title is more specific: window titles name the *document* ("Inbox (3) -
; Gmail - Google Chrome"), not the app. The title is only reached when there's no
; version info to read.
GetLogicalAppDisplayName(Window) {
	if !Window {
		return ""
	}
	if LogicalAppNameCache.Has(Window) {
		return LogicalAppNameCache[Window]
	}

	Name := ResolveIndirectString(GetWindowAppModelProperty(Window, PID_AppUserModel_RelaunchDisplayNameResource))

	if (Name = "") {
		Shortcut := FindShortcutForAppUserModelId(GetCachedWindowAppUserModelId(Window))
		if Shortcut {
			Name := Shortcut.Name
		}
	}

	if (Name = "") {
		Name := GetAppsFolderDisplayName(GetCachedWindowAppUserModelId(Window))
	}

	ProcessPath := ""
	try {
		ProcessPath := WinGetProcessPath(Window)
	} catch {
	}

	if (Name = "" && ProcessPath != "") {
		Name := GetExecutableDisplayName(ProcessPath)
	}

	if (Name = "") {
		try {
			Name := WinGetTitle(Window)
		} catch {
		}
	}

	if (Name = "" && ProcessPath != "") {
		; Without the extension: this is a name to show a person, not a path.
		SplitPath(ProcessPath, , , , &FileNameWithoutExtension)
		Name := FileNameWithoutExtension
	}

	LogicalAppNameCache[Window] := Name
	return Name
}

; The executable's own idea of its name, from the version resource that the shell exposes as
; ordinary properties. Read through the same property store machinery as everything else here;
; the hand-rolled version-resource reader this replaced truncated 64-bit pointers in three
; places and only worked while its buffer happened to land below 4 GB.
;
; An executable with no description doesn't come back empty: the shell answers with the file
; name instead. Measured on the Store build of Notepad, which carries no description at all --
; System.FileDescription reads back "Notepad.exe", so the switcher labelled it that.
;
; That echo is answered by dropping the extension rather than by rejecting it, which matters:
; rejecting it would fall through to the window title, and titles name the *document* rather
; than the application ("*Notes.txt - Notepad"). A bare "Notepad" is what the switcher wants,
; and an executable whose description is its own file name has told us nothing else useful.
GetExecutableDisplayName(ProcessPath) {
	if ExecutableDisplayNameCache.Has(ProcessPath) {
		return ExecutableDisplayNameCache[ProcessPath]
	}
	Name := GetFirstFileShellProperty(ProcessPath, PKEY_Version_FMTID, PID_FileDescription, PID_ProductName)
	SplitPath(ProcessPath, &FileName, , , &FileNameWithoutExtension)
	if (Name = FileName) {
		Name := FileNameWithoutExtension
	}
	ExecutableDisplayNameCache[ProcessPath] := Name
	return Name
}

; Returns an HICON for the logical application a window belongs to, or 0.
;
; Hierarchy:
;   1. System.AppUserModel.RelaunchIconResource on the window (Chrome points this at
;      the profile icon for browser windows)
;   2. The icon of the Start Menu / pinned shortcut with the same AUMID (this is what
;      gives each installed PWA its real icon instead of Chrome's)
;   3. The icon of the AUMID's AppsFolder entry (this is what gives packaged apps their
;      icon; without it Settings and the Microsoft Store have none at all, since every
;      other step comes back empty for a window hosted by ApplicationFrameHost.exe)
;   4. The window's own icon (WM_GETICON, then the window class icon)
;   5. The executable's first icon
;
; Icons from steps 1, 2, 3 and 5 are made by us and cached, so repeatedly opening the
; switcher can't leak handles. Icons from step 4 belong to the other application and
; must not be destroyed.
GetLogicalAppIconHandle(Window) {
	if !Window {
		return 0
	}

	IconHandle := LoadIconFromResourceString(ResolveIndirectString(GetWindowAppModelProperty(Window, PID_AppUserModel_RelaunchIconResource)))
	if IconHandle {
		return IconHandle
	}

	Shortcut := FindShortcutForAppUserModelId(GetCachedWindowAppUserModelId(Window))
	if Shortcut {
		IconHandle := GetShortcutIconHandle(Shortcut.Path)
		if IconHandle {
			return IconHandle
		}
	}

	IconHandle := GetAppsFolderIconHandle(GetCachedWindowAppUserModelId(Window))
	if IconHandle {
		return IconHandle
	}

	IconHandle := GetWindowIconHandle(Window)
	if IconHandle {
		return IconHandle
	}

	try {
		ProcessPath := WinGetProcessPath(Window)
	} catch {
		return 0
	}
	if (ProcessPath = "") {
		return 0
	}
	return LoadIconFromResourceString(ProcessPath ",0")
}

; Cached by path, so a rebuilt shortcut index reuses icons rather than orphaning them.
; A cached 0 means "tried, and there is none", which is worth remembering too.
GetShortcutIconHandle(ShortcutPath) {
	if ShortcutIconCache.Has(ShortcutPath) {
		return ShortcutIconCache[ShortcutPath]
	}
	IconHandle := LoadIconFromShortcut(ShortcutPath)
	ShortcutIconCache[ShortcutPath] := IconHandle
	return IconHandle
}

LoadIconFromShortcut(ShortcutPath) {
	IconFile := ""
	IconNumber := 0
	Target := ""
	try {
		FileGetShortcut(ShortcutPath, &Target, , , , &IconFile, &IconNumber)
	} catch {
		return 0
	}
	if (IconFile != "") {
		; FileGetShortcut reports a 1-based icon number, while ExtractIconEx takes a
		; 0-based index.
		IconIndex := (IsInteger(IconNumber) && IconNumber > 0) ? IconNumber - 1 : 0
		IconHandle := LoadIconFromResourceString(ExpandEnvironmentStrings(IconFile) "," IconIndex)
		if IconHandle {
			return IconHandle
		}
	}
	if (Target != "") {
		return LoadIconFromResourceString(ExpandEnvironmentStrings(Target) ",0")
	}
	return 0
}

; Resolves the "@path,-resourceId" form that app model resource properties may use.
; Plain strings are returned unchanged. Returns "" if an indirect string can't be
; resolved, so that callers fall through to the next item in their hierarchy rather
; than displaying something like "@C:\Program Files\...\chrome.dll,-12345".
ResolveIndirectString(Source) {
	static MaxCharacters := 1024
	if (Source = "") {
		return ""
	}
	if (SubStr(Source, 1, 1) != "@") {
		return Source
	}
	; One character of slack beyond what the API is allowed to write, and zero filled, so
	; that the result is null-terminated no matter what the API does.
	OutputBuffer := Buffer((MaxCharacters + 1) * 2, 0)
	try {
		if (DllCall("shlwapi\SHLoadIndirectString", "wstr", Source, "ptr", OutputBuffer, "uint", MaxCharacters, "ptr", 0, "int") = 0) {
			return StrGet(OutputBuffer, "UTF-16")
		}
	} catch {
	}
	return ""
}

; Loads an icon from a "<path>,<index>" resource string, as stored in
; System.AppUserModel.RelaunchIconResource. A negative index is a resource ID rather
; than an index, which ExtractIconEx handles natively.
LoadIconFromResourceString(Resource) {
	if (Resource = "") {
		return 0
	}
	if LogicalAppIconCache.Has(Resource) {
		return LogicalAppIconCache[Resource]
	}

	; Split on the *last* comma, since paths may (very rarely) contain one.
	CommaPosition := InStr(Resource, ",", , -1)
	if CommaPosition {
		Path := SubStr(Resource, 1, CommaPosition - 1)
		Index := Trim(SubStr(Resource, CommaPosition + 1))
	} else {
		Path := Resource
		Index := 0
	}
	Path := Trim(Trim(Path), '"')
	if !IsInteger(Index) {
		Index := 0
	}

	IconHandle := 0
	if (Path != "" && FileExist(Path)) {
		LargeIcon := 0
		try {
			; Asking only for the large icon gives us 32x32 (SM_CXICON), which is the size
			; the app switcher draws.
			DllCall("shell32\ExtractIconExW", "wstr", Path, "int", Integer(Index), "ptr*", &LargeIcon, "ptr", 0, "uint", 1, "uint")
			IconHandle := LargeIcon
		} catch {
			IconHandle := 0
		}
	}

	LogicalAppIconCache[Resource] := IconHandle
	return IconHandle
}

; The system's stock application icon, for an application whose own icon can't be found by
; any means. Like the window icons below it belongs to the system and must not be destroyed.
; Showing a placeholder is the point: an application the user can see on screen should never
; be missing from the switcher just because its icon couldn't be resolved.
GenericAppIconHandle() {
	static IconHandle := 0
	if !IconHandle {
		IconHandle := DllCall("user32\LoadIconW", "ptr", 0, "ptr", IDI_APPLICATION, "ptr")
	}
	return IconHandle
}

; Returns the icon a window advertises for itself, or 0. This handle belongs to the
; other application, so it must not be destroyed.
;
; The explicit 200 ms timeouts matter because this runs on the interactive Alt+Tab path,
; before the panel is on screen, once per application, and is not cached -- unlike display
; names, which memoize in LogicalAppNameCache. `SendMessage`'s default is 5000 ms, so three
; slow-to-pump windows could hold the keypress for fifteen seconds. (Whether a *hung* window
; short-circuits sooner is an undocumented implementation detail of AutoHotkey's, so the
; worst case is worth bounding rather than relying on.) A window that doesn't answer in
; 200 ms yields no icon, which the caller already handles: it falls through to the
; executable's icon and then to the stock application icon.
GetWindowIconHandle(Window) {
	IconHandle := 0
	try {
		IconHandle := SendMessage(WM_GETICON, ICON_BIG, 0, , Window, , , , 200)
	} catch {
	}
	if (!IconHandle) {
		try {
			IconHandle := SendMessage(WM_GETICON, ICON_SMALL2, 0, , Window, , , , 200)
		} catch {
		}
	}
	if (!IconHandle) {
		try {
			IconHandle := SendMessage(WM_GETICON, ICON_SMALL, 0, , Window, , , , 200)
		} catch {
		}
	}
	if (!IconHandle) {
		try {
			IconHandle := GetClassLongPtr(Window, GCLP_HICON)
		} catch {
		}
	}
	if (!IconHandle) {
		try {
			IconHandle := GetClassLongPtr(Window, GCLP_HICONSM)
		} catch {
		}
	}
	return IconHandle
}

GetClassLongPtr(Window, Index) {
	; GetClassLongPtr is only a real export in 64-bit user32; in 32-bit builds the "Ptr"
	; names are macros for the plain GetClassLong functions.
	if (A_PtrSize = 8) {
		return DllCall("GetClassLongPtrW", "Ptr", Window, "int", Index, "Ptr")
	}
	return DllCall("GetClassLongW", "Ptr", Window, "int", Index, "uint")
}

; True if DWM is hiding the window even though it's still WS_VISIBLE. Treats any failure as
; "not cloaked", so that a window is only ever excluded on a definite answer.
IsWindowCloaked(Window) {
	Cloaked := 0
	try {
		if (DllCall("dwmapi\DwmGetWindowAttribute", "ptr", Window, "uint", DWMWA_CLOAKED, "int*", &Cloaked, "uint", 4, "int") != 0) {
			return false
		}
	} catch {
		return false
	}
	return Cloaked != 0
}

; A GUID string as the 16 raw bytes the COM APIs take.
GuidBuffer(GuidString) {
	Guid := Buffer(16, 0)
	if (DllCall("ole32\CLSIDFromString", "wstr", GuidString, "ptr", Guid, "int") != 0) {
		throw ValueError("Not a GUID: " GuidString)
	}
	return Guid
}

; The shell's view collection, bound once and kept for the life of the script. Returns 0 if
; it can't be reached, so callers degrade to "this window can't be hidden" rather than
; throwing on a hotkey thread.
;
; This must not be called from inside a keyboard hook callback: a cross-process COM call
; from there fails with RPC_E_CANTCALLOUT_ININPUTSYNCCALL. AutoHotkey runs hotkey bodies
; after the hook returns, so calling it from a hotkey is fine.
ApplicationViewCollectionPointer := 0
ApplicationViewCollection() {
	global ApplicationViewCollectionPointer
	if ApplicationViewCollectionPointer {
		return ApplicationViewCollectionPointer
	}
	try {
		ImmersiveShell := ComObject(CLSID_ImmersiveShell, IID_IServiceProvider)
		Collection := 0
		; The service id and the interface id are the same GUID for this one.
		if (ComCall(IServiceProvider_QueryService, ImmersiveShell
			, "ptr", GuidBuffer(IID_IApplicationViewCollection)
			, "ptr", GuidBuffer(IID_IApplicationViewCollection)
			, "ptr*", &Collection, "int") = 0) {
			ApplicationViewCollectionPointer := Collection
		}
	} catch {
		ApplicationViewCollectionPointer := 0
	}
	return ApplicationViewCollectionPointer
}

; The shell's view object for a window, or 0. The caller owns the reference and must
; `ObjRelease` it.
GetApplicationView(Window) {
	Collection := ApplicationViewCollection()
	if !Collection {
		return 0
	}
	View := 0
	try {
		if (ComCall(IApplicationViewCollection_GetViewForHwnd, Collection
			, "ptr", Window, "ptr*", &View, "int") != 0) {
			return 0
		}
	} catch {
		return 0
	}
	return View
}

; Whether the shell lists this view in Alt+Tab, or -1 if it can't be read.
GetViewShownInSwitchers(View) {
	Shown := -1
	try {
		if (ComCall(IApplicationView_GetShowInSwitchers, View, "int*", &Shown, "int") != 0) {
			return -1
		}
	} catch {
		return -1
	}
	return Shown
}

; Returns true only if the flag was actually written.
SetViewShownInSwitchers(View, Shown) {
	try {
		return ComCall(IApplicationView_SetShowInSwitchers, View, "int", Shown ? 1 : 0, "int") = 0
	} catch {
		return false
	}
}

ExpandEnvironmentStrings(Text) {
	if !InStr(Text, "%") {
		return Text
	}
	; The returned size is in characters, and includes the null terminator.
	Size := DllCall("kernel32\ExpandEnvironmentStringsW", "wstr", Text, "ptr", 0, "uint", 0, "uint")
	if !Size {
		return Text
	}
	OutputBuffer := Buffer(Size * 2, 0)
	if !DllCall("kernel32\ExpandEnvironmentStringsW", "wstr", Text, "ptr", OutputBuffer, "uint", Size, "uint") {
		return Text
	}
	return StrGet(OutputBuffer, "UTF-16")
}

;--------------------------------------------------------
; Window filtering
;--------------------------------------------------------

Switchable(Window) {
	; Heuristics determine if a window is in the taskbar
	; https://stackoverflow.com/a/2262791
	; TODO: priority of conditions (I couldn't find a definitive source, but someone gives an order in one of the answers)
	ExStyle := WinGetExStyle(Window)
	if ExStyle & WS_EX_TOOLWINDOW {
		return false
	}
	; Cloaked windows are still WS_VISIBLE, so WinGetList hands them to us: suspended UWP
	; frames, the shell's own CoreWindows (TextInputHost, ShellExperienceHost) and anything
	; on another virtual desktop. None of them are in the task switcher. A minimized UWP
	; window is cloaked as well and *is* in the task switcher, hence the exemption.
	if (IsWindowCloaked(Window) && WinGetMinMax(Window) != -1) {
		return false
	}
	if ExStyle & WS_EX_APPWINDOW {
		return true
	}
	Style := WinGetStyle(Window)
	return !(Style & WS_CHILD)

	; Not sure of the specific rules, or how much the priority of the cases matters.
	; AI-autocompleted logic is slightly different:
	; Style := WinGetStyle(Window)
	; ExStyle := WinGetExStyle(Window)
	; if Style & WS_CHILD {
	;   return false
	; }
	; if ExStyle & WS_EX_APPWINDOW {
	;   return true
	; }
	; if ExStyle & WS_EX_TOOLWINDOW {
	;   return false
	; }
	; return true
}

;--------------------------------------------------------
; Coordination between the two switchers
;--------------------------------------------------------
; window-switcher.ahk drives the *native* Windows task switcher by synthesizing
; Alt+Tab, and app-switcher.ahk owns the physical Alt+Tab hotkey. Those two facts have
; to be reconciled.
;
; The synthetic Alt+Tab is not actually a problem: AutoHotkey tags the input it
; generates with a send level (0 unless SendLevel says otherwise), and hook hotkeys
; such as `$!Tab` ignore generated input at or below their own input level. The tag is
; a value all AutoHotkey builds recognize, so this works between separate scripts too.
; window-switcher's `Send` therefore reaches Windows without re-triggering the app
; switcher. (Verified: a level-0 synthetic Alt+Tab opens the native switcher and never
; fires `$!Tab`, while a level-1 one fires `$!Tab` and is swallowed.)
;
; What that does *not* cover is the physical Tab presses a user makes to cycle through
; the native switcher once it's open. Those are indistinguishable from asking for the
; app switcher. So while window-switcher has the native switcher open it holds a named
; mutex, and app-switcher passes Tab straight through instead of opening its own UI.
;
; A named mutex is used rather than window messages because it works regardless of
; script names, works when compiled, and is released by the kernel automatically if the
; window switcher exits or crashes mid-session. Either script also works fine on its
; own: with the other one not running, the mutex simply never exists.

; "Local\" scopes the mutex to the current logon session.
NATIVE_SWITCHER_SESSION_MUTEX_NAME := "Local\1j01-window-switcher-native-task-switcher-session"
NativeSwitcherSessionMutex := 0

BeginNativeSwitcherSession() {
	global NativeSwitcherSessionMutex
	if NativeSwitcherSessionMutex {
		return
	}
	NativeSwitcherSessionMutex := DllCall("kernel32\CreateMutexW", "ptr", 0, "int", false, "wstr", NATIVE_SWITCHER_SESSION_MUTEX_NAME, "ptr")
}

EndNativeSwitcherSession() {
	global NativeSwitcherSessionMutex
	if !NativeSwitcherSessionMutex {
		return
	}
	DllCall("kernel32\CloseHandle", "ptr", NativeSwitcherSessionMutex)
	NativeSwitcherSessionMutex := 0
}

; True if *this* script is the one currently driving the native task switcher.
NativeSwitcherSessionOwnedHere() {
	return NativeSwitcherSessionMutex != 0
}

; True if any script is currently driving the native task switcher.
IsNativeSwitcherSessionActive() {
	static SYNCHRONIZE := 0x00100000
	static ERROR_ACCESS_DENIED := 5
	Handle := DllCall("kernel32\OpenMutexW", "uint", SYNCHRONIZE, "int", false, "wstr", NATIVE_SWITCHER_SESSION_MUTEX_NAME, "ptr")
	if Handle {
		DllCall("kernel32\CloseHandle", "ptr", Handle)
		return true
	}
	; If the window switcher is running as administrator and this script isn't, opening
	; the mutex can fail with access denied -- which still tells us that it exists.
	return A_LastError = ERROR_ACCESS_DENIED
}

;--------------------------------------------------------
; Tray menu
;--------------------------------------------------------
; Both switchers add the same two items pointing at the same project, so the definition
; lives here rather than being duplicated. The two tray icons stay separate regardless --
; they are separate processes.

; Named once, since the handler matches on it.
ELEVATION_TRAY_ITEM_NAME := "Why doesn't this work over Task Manager?"

AddSwitcherTrayMenuItems() {
	A_TrayMenu.Add()  ; Creates a separator line.
	; Windows won't let a process hook keystrokes that are on their way to a window of a
	; more privileged process, so while an elevated window is focused the hotkeys don't fire
	; at all and Windows' own Alt+Tab takes over. That looks exactly like the script having
	; crashed, so say so somewhere the user can find it rather than leaving them guessing.
	if !A_IsAdmin {
		A_IconTip := StrReplace(A_ScriptName, ".ahk") " (not running as administrator: the shortcuts are inactive while an administrator window is focused)"
		A_TrayMenu.Add(ELEVATION_TRAY_ITEM_NAME, SwitcherTrayMenuHandler)
	}
	A_TrayMenu.Add("Report Issue", SwitcherTrayMenuHandler)
	A_TrayMenu.Add("Project Homepage", SwitcherTrayMenuHandler)
}

SwitcherTrayMenuHandler(ItemName, ItemPos, MyMenu) {
	if ItemName = "Report Issue" {
		Run("https://github.com/1j01/window-switcher/issues")
	} else if ItemName = "Project Homepage" {
		Run("https://github.com/1j01/window-switcher/?tab=readme-ov-file#window-switcher")
	} else if (ItemName = ELEVATION_TRAY_ITEM_NAME) {
		MsgBox(
			"Windows doesn't let a program intercept keystrokes on their way to a program running with "
			. "higher privileges, so while a window belonging to an administrator process is focused, "
			. "Alt+Tab and Alt+`` never reach this script and Windows' own switcher takes over.`n`n"
			. "Task Manager is the one that usually gives it away, because it runs as administrator "
			. "without asking. Registry Editor, Event Viewer, Services, installers and anything started "
			. "with `"Run as administrator`" all behave the same way.`n`n"
			. "Switching *to* one of those apps works; it's only switching away from one that doesn't.`n`n"
			. "Running this script as administrator fixes it. See `"Running on Startup`" in the readme "
			. "for how to do that without a UAC prompt at every logon."
			, "Why don't the shortcuts work over Task Manager?", 0x40)
	}
}

;--------------------------------------------------------
; Misc. helpers
;--------------------------------------------------------

MakeSplash(Title, Text, Duration := 0) {
	SplashGui := Gui(, Title)
	SplashGui.Opt("+AlwaysOnTop +Disabled -SysMenu +Owner")  ; +Owner avoids a taskbar button.
	SplashGui.Add("Text", , Text)
	SplashGui.Show("NoActivate")  ; NoActivate avoids deactivating the currently active window.
	if Duration {
		Sleep(Duration)
		SplashGui.Destroy()
	}
	return SplashGui
}

; Only ever used to describe a window in an error message, so it must not be able to raise an
; error of its own -- it is called from `RestoreHiddenWindows`, on the path that puts windows
; back in the taskbar. `TargetError` alone wasn't enough: `WinGetProcessPath` throws `OSError`
; for a process we aren't allowed to query, which is precisely the elevated-window case that
; gets us into that error handler in the first place.
DescribeWindow(Window) {
	try {
		return "Window Title: " WinGetTitle(Window) "`nWindow Class: " WinGetClass(Window) "`nProcess Path: " WinGetProcessPath(Window) "`nLogical App: " GetLogicalAppId(Window)
	} catch TargetError {
		return "Nonexistent window"
	} catch {
		return "Window " Window " (couldn't be described)"
	}
}
