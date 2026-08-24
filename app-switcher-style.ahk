#Requires AutoHotkey v2.0

;--------------------------------------------------------
; App Switcher styling
;--------------------------------------------------------
; How the app switcher *looks*, kept apart from what it does. `app-switcher.ahk` owns the
; behaviour and calls into here for every presentation decision.
;
; The target is the real Windows 11 Alt+Tab switcher. The numbers below were measured off
; screenshots of it against both a white and a black background -- the pair is what makes it
; possible to tell a flat colour from a translucent one -- rather than eyeballed. Measurements
; were taken on a 150% display and are recorded here in *effective* pixels, the DPI-independent
; unit AutoHotkey Gui coordinates use (`+DPIScale`, the default, multiplies them by A_ScreenDPI
; for us). The physical pixel counts are quoted in the comments so that every value can be
; re-checked against a fresh screenshot.
;
; What the two-background comparison established, for the record:
;   - The panel is *not* translucent. It is a flat #202020 -- byte-identical over white and
;     over black -- because the reference machine has "Transparency effects" turned off, which
;     is a setting we can read, so the switcher follows it instead of hardcoding either look.
;   - The 1px outer border *is* translucent: 200 over white and 47 over black, which solves to
;     40% of #757575, i.e. exactly WinUI's `SurfaceStrokeColorDefault`. DWM already draws that
;     for us (see `ApplyAppSwitcherFrame` below), so nothing here needs to reproduce it.
;   - The selection ring is a flat, fully opaque #45E532, which is this machine's
;     `SystemAccentColorLight2` -- the accent colour, not a fixed blue or green, and not the
;     base accent either but the light-on-dark shade of it.
;   - There is no drop shadow: the pixels immediately outside the border are untouched.

;--------------------------------------------------------
; Measured geometry
;--------------------------------------------------------

class AppSwitcherStyle {
	; -- Panel ----------------------------------------------------------------------------
	; Padding around the items. Windows leaves 56 epx (84 physical px) around its window
	; preview cards; that is 16% of a card's width, and this is the same fraction of our much
	; smaller icon tiles, so the panel keeps the real switcher's airiness without the tiles
	; drowning in it.
	static PanelPadding := 28
	; The panel's corner radius is 8 epx (12 physical px, measured). We don't draw it: DWM
	; does, via DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND, which *is* 8 epx. Recorded here
	; only so the value is written down next to everything else.
	static PanelCornerRadius := 8

	; -- Items ----------------------------------------------------------------------------
	; Our entries are app icons, not window previews, so they are much smaller than the
	; 343x184 epx cards Windows shows. Everything that isn't a width or a height is kept at
	; the real switcher's value.
	static ItemSize := 128
	; Measured 36 physical px between adjacent cards, horizontally and vertically alike.
	static ItemGap := 24
	; Measured ~20 physical px on an unselected card, and confirmed by the selection ring's
	; own radius, which is exactly this plus the ring's offset from the item.
	static ItemCornerRadius := 12
	; 32 is as large as an icon fetched through WM_GETICON gets, so it is also the largest we
	; can show without upscaling. (See the TODO in app-switcher.ahk.)
	static IconSize := 32
	static IconToLabelGap := 14
	static LabelHeight := 18
	static LabelInset := 10
	; Points. Windows 11's "Body" style, which its card titles use, is 14 epx == 10.5pt.
	static LabelFontSize := 10

	; -- Selection ------------------------------------------------------------------------
	; The heart of the match. Windows draws the selected card's highlight as two concentric
	; rounded strokes sitting *outside* the card, with a sliver of panel showing between them
	; and the card itself. Measured from the panel inwards: 6 physical px of accent, 3 of
	; #0A0A0A, then 6 of plain panel background before the card starts.
	static SelectionAccentThickness := 4
	static SelectionInnerThickness := 2
	static SelectionGap := 4

	; -- Derived --------------------------------------------------------------------------
	; How far the highlight reaches beyond the item box, and hence how big the image behind
	; each item has to be. With a 24 epx gap between items, adjacent highlights end up 4 epx
	; apart -- which is what Windows' do.
	static SelectionExtent := this.SelectionGap + this.SelectionInnerThickness + this.SelectionAccentThickness
	static SelectionBoxSize := this.ItemSize + 2 * this.SelectionExtent
	static SelectionOuterRadius := this.ItemCornerRadius + this.SelectionExtent
	static ItemContentHeight := this.IconSize + this.IconToLabelGap + this.LabelHeight
}

;--------------------------------------------------------
; Measured colours
;--------------------------------------------------------
; These are WinUI theme resources. The dark ones aren't taken on trust: `PanelSurface` and
; `ItemSurface` are the two values actually measured in the reference screenshots, and they
; turn out to be `SolidBackgroundFillColorBase` and `SolidBackgroundFillColorBaseAlt` exactly.
; The light-theme counterparts are the documented light values of the same resources; the
; reference machine is in dark mode, so those are the one group here that a screenshot didn't
; confirm.

class AppSwitcherColors {
	; SolidBackgroundFillColorBase -- the panel. #202020 measured.
	static PanelSurfaceDark := 0x202020
	static PanelSurfaceLight := 0xF3F3F3
	; SolidBackgroundFillColorBaseAlt -- the surface a card sits on, and therefore the colour
	; of the highlight's inner stroke. #0A0A0A measured.
	static ItemSurfaceDark := 0x0A0A0A
	static ItemSurfaceLight := 0xDADADA
	; TextFillColorPrimary. White measured on the card titles.
	static TextDark := 0xFFFFFF
	static TextLight := 0x1A1A1A
	; Only reached if the accent palette can't be read at all; the shades Windows derives from
	; its own default accent (#0078D4).
	static FallbackAccentDark := 0x4CC2FF
	static FallbackAccentLight := 0x005FB8
}

;--------------------------------------------------------
; Windows settings the switcher follows
;--------------------------------------------------------

PERSONALIZE_KEY := "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"

; Whether apps -- and so the switcher -- should use the dark surfaces. Dark is the Windows 11
; default, so that's what an unreadable setting falls back to.
DarkModeEnabled() {
	try {
		return RegRead(PERSONALIZE_KEY, "AppsUseLightTheme") = 0
	}
	return true
}

; Settings > Personalisation > Colours > Transparency effects. This is the switch that decides
; whether the real Alt+Tab panel is acrylic or the flat colour seen in the reference
; screenshots, so it decides ours too.
TransparencyEffectsEnabled() {
	try {
		return RegRead(PERSONALIZE_KEY, "EnableTransparency") != 0
	}
	return true
}

; Whether the panel should be a DWM acrylic surface rather than a flat one. The real switcher
; is acrylic exactly when transparency effects are on, which is also what decides whether the
; highlight images can be left transparent -- see EnsureAppSwitcherImages.
; 22621 is 22H2, the documented minimum for DWMWA_SYSTEMBACKDROP_TYPE.
AppSwitcherPanelIsAcrylic() => TransparencyEffectsEnabled() && (VerCompare(A_OSVersion, "10.0.22621") >= 0)

; Windows keeps eight shades of the accent colour in one binary registry value, four bytes
; each (R, G, B and an unused byte), in this order:
;   AccentLight3, AccentLight2, AccentLight1, Accent, AccentDark1, AccentDark2, AccentDark3
; and then an unrelated grey. Confirmed on this machine against
; Windows.UI.ViewManagement.UISettings.GetColorValue, which is the documented API for the same
; colours but isn't reachable from AutoHotkey.
ACCENT_PALETTE_LIGHT_2 := 1
ACCENT_PALETTE_DARK_1 := 4

; Returns 0xRRGGBB, or "" if the palette isn't readable.
GetAccentPaletteColor(Index) {
	Palette := ""
	try {
		; RegRead hands back REG_BINARY as a string of hex digits.
		Palette := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent", "AccentPalette")
	}
	if (StrLen(Palette) < (Index + 1) * 8) {
		return ""
	}
	; The bytes are stored R, G, B, so the first six hex digits of an entry already read as
	; 0xRRGGBB.
	Entry := SubStr(Palette, Index * 8 + 1, 6)
	if !RegExMatch(Entry, "^[0-9A-Fa-f]{6}$") {
		return ""
	}
	return Integer("0x" Entry)
}

; The colour the highlight is drawn in: WinUI's `AccentFillColorDefault`, which is
; AccentLight2 on dark surfaces and AccentDark1 on light ones. AccentLight2 is what the
; reference screenshot's ring matched exactly.
SelectionAccentColor(Dark) {
	Color := GetAccentPaletteColor(Dark ? ACCENT_PALETTE_LIGHT_2 : ACCENT_PALETTE_DARK_1)
	if (Color != "") {
		return Color
	}
	return Dark ? AppSwitcherColors.FallbackAccentDark : AppSwitcherColors.FallbackAccentLight
}

PanelSurfaceColor(Dark) => Dark ? AppSwitcherColors.PanelSurfaceDark : AppSwitcherColors.PanelSurfaceLight
ItemSurfaceColor(Dark) => Dark ? AppSwitcherColors.ItemSurfaceDark : AppSwitcherColors.ItemSurfaceLight
LabelTextColor(Dark) => Dark ? AppSwitcherColors.TextDark : AppSwitcherColors.TextLight

;--------------------------------------------------------
; Layout
;--------------------------------------------------------
; All in Gui units (effective pixels), i.e. what `Gui.Add` and `Gui.Show` want.

; The work area of the monitor holding `AnchorWindow`, in physical pixels, falling back to
; the primary monitor's. This is what the panel is sized against and centred in.
AppSwitcherWorkArea(AnchorWindow := 0) {
	if AnchorWindow {
		CenterX := "", CenterY := ""
		try {
			WinGetPos(&WindowX, &WindowY, &WindowWidth, &WindowHeight, AnchorWindow)
			CenterX := WindowX + WindowWidth // 2
			CenterY := WindowY + WindowHeight // 2
		} catch {
			; The window may be gone, or minimized (which reports nonsense coordinates that
			; simply won't match any monitor below).
		}
		if (CenterX != "") {
			Loop MonitorGetCount() {
				try {
					MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
				} catch {
					continue
				}
				if (CenterX >= Left && CenterX < Right && CenterY >= Top && CenterY < Bottom) {
					return MonitorWorkArea(A_Index)
				}
			}
		}
	}
	return MonitorWorkArea(MonitorGetPrimary())
}

MonitorWorkArea(Index) {
	MonitorGetWorkArea(Index, &Left, &Top, &Right, &Bottom)
	return { Left: Left, Top: Top, Width: Right - Left, Height: Bottom - Top }
}

; How the items are arranged, given the room available on the target monitor.
;
; A single row was the original arrangement, and it broke down silently: the panel is
; `2*28 + N*128 + (N-1)*24` epx wide, so at 1920x150% (1280 epx of room) the ninth app
; already put items past the edge of the screen, where they could only be tabbed through
; blind. Windows wraps its cards into a grid instead, so this does too -- as many columns
; as fit, then as many rows as needed.
;
; `ItemsShown` can be less than `ItemCount`, when not even a full grid holds everything.
; Callers pass apps in recency order, so what gets dropped is the least recently used.
; (Windows scrolls in this situation; we don't.)
AppSwitcherPanelLayout(ItemCount, AvailableWidth, AvailableHeight) {
	Step := AppSwitcherStyle.ItemSize + AppSwitcherStyle.ItemGap
	Padding := 2 * AppSwitcherStyle.PanelPadding
	; The gap is added back in because the last column and row don't need one after them.
	MaxColumns := Max(1, (AvailableWidth - Padding + AppSwitcherStyle.ItemGap) // Step)
	MaxRows := Max(1, (AvailableHeight - Padding + AppSwitcherStyle.ItemGap) // Step)
	ItemsShown := Min(Max(ItemCount, 0), MaxColumns * MaxRows)
	Columns := Max(1, Min(MaxColumns, ItemsShown))
	Rows := Max(1, Ceil(ItemsShown / Columns))
	return {
		Columns: Columns,
		Rows: Rows,
		ItemsShown: ItemsShown,
		Width: Padding + Columns * AppSwitcherStyle.ItemSize + (Columns - 1) * AppSwitcherStyle.ItemGap,
		Height: Padding + Rows * AppSwitcherStyle.ItemSize + (Rows - 1) * AppSwitcherStyle.ItemGap,
	}
}

; Where an item's box goes, given its one-based position and the width of the grid. The box
; is the icon-and-label area; the highlight is drawn `SelectionExtent` outside it. Items are
; placed row-major, which is the order the controls are added in, and hence the Tab order.
AppSwitcherItemPosition(Index, Columns) {
	Step := AppSwitcherStyle.ItemSize + AppSwitcherStyle.ItemGap
	return {
		X: AppSwitcherStyle.PanelPadding + Mod(Index - 1, Columns) * Step,
		Y: AppSwitcherStyle.PanelPadding + ((Index - 1) // Columns) * Step
	}
}

;--------------------------------------------------------
; The panel's frame
;--------------------------------------------------------
; The rounded corners and the translucent 1px outer border are both DWM's work, not ours.
;
; This used to go through GuiEnhancerKit's `SetBorderless`, which does the same attribute
; setting but *also* subclasses the window to handle WM_NCCALCSIZE / WM_NCHITTEST /
; WM_ACTIVATE. None of that is wanted here: the Gui is created `-Caption -Border`, so there
; is no non-client frame to strip and no reason for a transient panel to have resize
; borders. The subclass was also actively harmful -- its registry is keyed by HWND and
; cleaned up on the Gui's `Close` event, which `Gui.Destroy` never raises, so every session
; leaked a callback thunk, and once Windows recycled an HWND the stale handlers ran against
; a destroyed Gui and threw "Error: Gui has no window."

; Note that DWMWINDOWATTRIBUTE is one-based: DWMWA_NCRENDERING_ENABLED is 1, not 0. Verified
; by measurement -- DWMWA_EXTENDED_FRAME_BOUNDS is the only one of 8 and 9 that returns a RECT
; matching the window, and it is 9; DWMWA_CLOAKED is likewise 14 rather than 13.
; https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
DWMWA_TRANSITIONS_FORCEDISABLED := 3
DWMWA_WINDOW_CORNER_PREFERENCE := 33
; https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwm_window_corner_preference
DWMWCP_ROUND := 2

; `Inset` is how far to extend the DWM frame into the client area, or "" for "all the way".
;
; How far matters more than it looks. Extended across the whole window, the entire panel
; becomes glass: everything GDI paints there is composited with a zero alpha and vanishes,
; leaving only what DWM draws behind it. That is exactly right when DWM is drawing an
; acrylic backdrop, and exactly wrong when the panel is meant to be a flat colour, where it
; left the padding around the items showing the desktop instead of the surface. So the flat
; case extends the frame by a single pixel: enough for DWM to still draw the border and
; round the corners, while the client area stays ordinary opaque painting.
;
; The window has to be shown already when this is called.
ApplyAppSwitcherFrame(PanelGui, Inset := "") {
	; No open/close animation on a panel that appears and disappears with a keypress. (This is
	; what `SetBorderless` set, and it's kept for behavioural parity with it.)
	PanelGui.SetWindowAttribute(DWMWA_TRANSITIONS_FORCEDISABLED, true)
	; Rounded corners, and the translucent 1px outer border along with them. DWMWCP_ROUND's
	; radius is 8 epx, which is the radius the real Alt+Tab panel has.
	if (VerCompare(A_OSVersion, "10.0.22000") >= 0) {
		PanelGui.SetWindowAttribute(DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND)
	}
	Rect := Buffer(16, 0)
	DllCall("GetWindowRect", "ptr", PanelGui.Hwnd, "ptr", Rect)
	Horizontal := Inset = "" ? NumGet(Rect, 8, "int") - NumGet(Rect, 0, "int") : Inset
	Vertical := Inset = "" ? NumGet(Rect, 12, "int") - NumGet(Rect, 4, "int") : Inset
	; struct MARGINS { int cxLeftWidth, cxRightWidth, cyTopHeight, cyBottomHeight; }
	Margins := Buffer(16, 0)
	NumPut("int", Horizontal, "int", Horizontal, "int", Vertical, "int", Vertical, Margins)
	DllCall("dwmapi\DwmExtendFrameIntoClientArea", "ptr", PanelGui.Hwnd, "ptr", Margins)
}

;--------------------------------------------------------
; The highlight images
;--------------------------------------------------------
; The highlight used to be a pre-drawn PNG, which meant a hardcoded blue that ignored the
; accent colour and a shape that stretched with the display scaling. It's now drawn with GDI+
; at the exact pixel size the Picture control will occupy, so the accent colour, the stroke
; widths and the corner radius are all right at any DPI.
;
; They're written out as PNG *files* and handed to Picture controls by path, the same way the
; pre-drawn images were.
;
; A Picture control does not reliably alpha-blend what it's given -- an image that is entirely
; transparent comes out solid black -- so the images don't rely on it. When the panel is a flat
; colour, they are filled with that colour, which makes them opaque and exact: the fill is
; indistinguishable from the panel it sits on, and the strokes' anti-aliased edges blend into
; the real panel colour. When DWM is drawing an acrylic backdrop instead, they're left
; transparent, because there the window paints black where the backdrop should show through and
; black is precisely what an unblended transparent image gives us.

; Effective pixels to real ones, matching how AutoHotkey scales Gui coordinates.
ScaleToPixels(Value) => Round(Value * A_ScreenDPI / 96)
; ...and back, for turning physical measurements (monitor work areas, WinGetPos) into the
; Gui units that `Gui.Add` and `Gui.Show` take.
ScaleToGuiUnits(Value) => Round(Value * 96 / A_ScreenDPI)

AppSwitcherImageDir := A_Temp "\AppSwitcherImages\"
; Cached, and keyed by everything the images depend on, so that changing the accent colour or
; the theme while the script is running produces new images rather than stale ones.
AppSwitcherImageKey := ""
AppSwitcherSelectedImage := ""
AppSwitcherUnselectedImage := ""

EnsureAppSwitcherImages() {
	global AppSwitcherImageKey, AppSwitcherSelectedImage, AppSwitcherUnselectedImage
	Dark := DarkModeEnabled()
	Accent := SelectionAccentColor(Dark)
	Inner := ItemSurfaceColor(Dark)
	; "" means leave the image transparent; see the note above.
	Plate := AppSwitcherPanelIsAcrylic() ? "" : PanelSurfaceColor(Dark)
	Key := Format("{:d}-{:06X}-{:06X}-{}-{:d}", Dark ? 1 : 0, Accent, Inner
		, Plate = "" ? "acrylic" : Format("{:06X}", Plate), A_ScreenDPI)
	if (Key = AppSwitcherImageKey) {
		return
	}
	Size := ScaleToPixels(AppSwitcherStyle.SelectionBoxSize)
	Selected := AppSwitcherImageDir "selected-" Key ".png"
	Unselected := AppSwitcherImageDir "unselected-" Key ".png"
	try {
		if !DirExist(AppSwitcherImageDir) {
			DirCreate(AppSwitcherImageDir)
		}
		WriteSelectionImage(Selected, Size, Plate, Accent, Inner)
		WritePlateImage(Unselected, Size, Plate)
	} catch {
		; A_Temp not being writable shouldn't be fatal; fall through to the check below.
	}
	; None of the GDI+ calls report failure, and DirCreate can throw, so confirm the files are
	; actually there before caching the key. Caching it regardless would mean a single failed
	; write left the switcher permanently pointing Picture controls at files that don't exist.
	if (!FileExist(Selected) || !FileExist(Unselected)) {
		return
	}
	AppSwitcherSelectedImage := Selected
	AppSwitcherUnselectedImage := Unselected
	AppSwitcherImageKey := Key
}

; An unselected item gets no treatment at all, matching Windows, where selection is the only
; thing that distinguishes one card from another. The image is still drawn -- as bare panel, the
; same size as the selected one -- so that the two can be swapped without moving anything.
WritePlateImage(Path, Size, Plate) {
	Bitmap := CreateGdipBitmap(Size, Plate)
	SaveGdipBitmapAsPng(Bitmap, Path)
	DllCall("gdiplus\GdipDisposeImage", "ptr", Bitmap)
}

WriteSelectionImage(Path, Size, Plate, AccentColor, InnerColor) {
	Bitmap := CreateGdipBitmap(Size, Plate)
	DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", Bitmap, "ptr*", &Graphics := 0)
	; SmoothingModeAntiAlias, PixelOffsetModeHighQuality.
	DllCall("gdiplus\GdipSetSmoothingMode", "ptr", Graphics, "int", 4)
	DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", Graphics, "int", 2)

	OuterRadius := ScaleToPixels(AppSwitcherStyle.SelectionOuterRadius)
	AccentThickness := ScaleToPixels(AppSwitcherStyle.SelectionAccentThickness)
	InnerThickness := ScaleToPixels(AppSwitcherStyle.SelectionInnerThickness)
	; Outermost first: the accent ring flush with the image edge, then the dark stroke just
	; inside it. Both are opaque; Windows' are too.
	StrokeRoundedRectangle(Graphics, Size, OuterRadius, 0, AccentThickness, 0xFF000000 | AccentColor)
	StrokeRoundedRectangle(Graphics, Size, OuterRadius, AccentThickness, InnerThickness, 0xFF000000 | InnerColor)

	SaveGdipBitmapAsPng(Bitmap, Path)
	DllCall("gdiplus\GdipDeleteGraphics", "ptr", Graphics)
	DllCall("gdiplus\GdipDisposeImage", "ptr", Bitmap)
}

; `Inset` is how far this stroke's *outer* edge sits from the image's edge, so the strokes can
; be described the way they were measured: from the outside in.
StrokeRoundedRectangle(Graphics, Size, OuterRadius, Inset, Thickness, ARGB) {
	if (Thickness <= 0) {
		return
	}
	; A GDI+ pen straddles its path, so the path runs half a stroke inside the edge it covers.
	Offset := Inset + Thickness / 2
	DllCall("gdiplus\GdipCreatePen1", "uint", ARGB, "float", Thickness, "int", 2, "ptr*", &Pen := 0)
	DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &Path := 0)
	AddRoundedRectanglePath(Path, Offset, Offset, Size - 2 * Offset, Size - 2 * Offset, OuterRadius - Offset)
	DllCall("gdiplus\GdipDrawPath", "ptr", Graphics, "ptr", Pen, "ptr", Path)
	DllCall("gdiplus\GdipDeletePath", "ptr", Path)
	DllCall("gdiplus\GdipDeletePen", "ptr", Pen)
}

AddRoundedRectanglePath(Path, X, Y, Width, Height, Radius) {
	Diameter := Min(2 * Radius, Width, Height)
	if (Diameter <= 0) {
		DllCall("gdiplus\GdipAddPathRectangle", "ptr", Path, "float", X, "float", Y, "float", Width, "float", Height)
		return
	}
	; Four quarter-circles, starting at the top left and going clockwise.
	DllCall("gdiplus\GdipAddPathArc", "ptr", Path, "float", X, "float", Y, "float", Diameter, "float", Diameter, "float", 180, "float", 90)
	DllCall("gdiplus\GdipAddPathArc", "ptr", Path, "float", X + Width - Diameter, "float", Y, "float", Diameter, "float", Diameter, "float", 270, "float", 90)
	DllCall("gdiplus\GdipAddPathArc", "ptr", Path, "float", X + Width - Diameter, "float", Y + Height - Diameter, "float", Diameter, "float", Diameter, "float", 0, "float", 90)
	DllCall("gdiplus\GdipAddPathArc", "ptr", Path, "float", X, "float", Y + Height - Diameter, "float", Diameter, "float", Diameter, "float", 90, "float", 90)
	DllCall("gdiplus\GdipClosePathFigure", "ptr", Path)
}

; `Plate` is the colour to fill the bitmap with, or "" to leave it transparent.
CreateGdipBitmap(Size, Plate := "") {
	StartGdiplus()
	static PixelFormat32bppARGB := 0x26200A
	DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", Size, "int", Size, "int", 0, "int", PixelFormat32bppARGB, "ptr", 0, "ptr*", &Bitmap := 0)
	if (Plate != "") {
		DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", Bitmap, "ptr*", &Graphics := 0)
		DllCall("gdiplus\GdipGraphicsClear", "ptr", Graphics, "uint", 0xFF000000 | Plate)
		DllCall("gdiplus\GdipDeleteGraphics", "ptr", Graphics)
	}
	return Bitmap
}

SaveGdipBitmapAsPng(Bitmap, Path) {
	static PngEncoder := ""
	if (PngEncoder = "") {
		PngEncoder := Buffer(16, 0)
		DllCall("ole32\CLSIDFromString", "wstr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "ptr", PngEncoder)
	}
	DllCall("gdiplus\GdipSaveImageToFile", "ptr", Bitmap, "wstr", Path, "ptr", PngEncoder, "ptr", 0)
}

; GDI+ is only ever started, never shut down: the images may be regenerated at any point in the
; script's life, and the process ending is what releases it.
StartGdiplus() {
	static Token := 0
	if Token {
		return Token
	}
	if !DllCall("GetModuleHandle", "str", "gdiplus", "ptr") {
		DllCall("LoadLibrary", "str", "gdiplus", "ptr")
	}
	; GdiplusStartupInput: version, debug callback, suppress background thread, suppress
	; external codecs. Only the version matters to us.
	StartupInput := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
	NumPut("uint", 1, StartupInput, 0)
	DllCall("gdiplus\GdiplusStartup", "uptr*", &Token, "ptr", StartupInput, "ptr", 0)
	return Token
}
