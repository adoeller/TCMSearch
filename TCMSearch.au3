#Region ;**** Directives created by AutoIt3Wrapper_GUI ****
#AutoIt3Wrapper_Icon=app.ico
#AutoIt3Wrapper_UseUpx=y
#AutoIt3Wrapper_UseX64=y
#EndRegion ;**** Directives created by AutoIt3Wrapper_GUI ****
#Region ;**** Directives created by ChatGPT ****
#AutoIt3Wrapper_UseX64=y
#AutoIt3Wrapper_Icon=app.ico
#EndRegion
#include <Array.au3>
#include <File.au3>
#include <GUIConstantsEx.au3>
#include <GuiListView.au3>
#include <WindowsConstants.au3>
#include <WinAPI.au3>
#include <MsgBoxConstants.au3>
#include <EditConstants.au3>
#include <StaticConstants.au3>
#include <TrayConstants.au3>

; ═══════════════════════════════════════════════════════
;  TCMSearch – AutoIt3 Port
;  Hotkey-Mechanismus: HotKeySet() statt RegisterHotKey/GUIRegisterMsg
;  HotKeySet ist der native AutoIt-Weg und funktioniert zuverlässig
;  auch wenn kein Fenster fokussiert ist.
; ═══════════════════════════════════════════════════════

; _GetBaseDir MUSS vor allen Global-Deklarationen stehen die davon abhängen.
; AutoIt erlaubt Func-Aufrufe in Global-Initialisierungen nur wenn die Func
; bereits im Quelltext steht (bei Globals wird von oben nach unten ausgewertet).
Func _GetBaseDir()
    ; Kompiliert (@Compiled=1): @AutoItExe = Pfad der .exe
    ; Interpretiert (@Compiled=0): @ScriptFullPath = Pfad der .au3
    Local $fullpath = @Compiled ? @AutoItExe : @ScriptFullPath
    Local $lastSlash = StringInStr($fullpath, "\", 0, -1)
    If $lastSlash > 0 Then Return StringLeft($fullpath, $lastSlash - 1)
    Return @ScriptDir  ; Fallback, sollte nie eintreten
EndFunc

; Basispfad und davon abhängige Pfade – jetzt sicher nach _GetBaseDir()
Global $g_BaseDir    = _GetBaseDir()
Global $g_ConfigPath = $g_BaseDir & "\config.ini"
Global Const $ICON_FILE = $g_BaseDir & "\app.ico"

Global Const $APP_NAME      = "TCMSearch"
Global Const $TC_CLASS_32   = "TTOTAL_CMD"
Global Const $TC_CLASS_64   = "TTOTAL_CMD64"
Global Const $EM_COMMAND_DW = 19781
Global Const $tagCDS        = "uptr dwData;dword cbData;ptr lpData"
Global Const $WM_COPYDATA_MSG = 0x004A

Global $g_Buttons[0][6]
Global $g_CurrentRows[0]
Global $g_hGUI    = 0
Global $g_hInput  = 0
Global $g_hList   = 0
Global $g_hStatus = 0
Global $g_hHint   = 0  ; Custom-Hint-Label über dem Input
Global $g_TCPath  = ""
Global $g_TCOnly  = True
Global $g_HotKeyStr = "^{SPACE}"   ; AutoIt-Syntax: ^ = Ctrl
Global $g_WinW   = 660
Global $g_WinH   = 440
Global $g_WinX      = -1
Global $g_WinY      = -1
Global $g_MaxResults = 200

; Tray-Items
Global $g_TI_Reload   = 0
Global $g_TI_Settings = 0
Global $g_TI_Exit     = 0

; Interne Flags – kein Blocking durch MsgBox im Callback
Global $g_TogglePending = False

; ──────────────────────────────────────────────────────
;  Start
; ──────────────────────────────────────────────────────
_Config_Load()
_Buttons_LoadAll()
_GUI_Build()
_Tray_Build()
_Hotkey_Set()

; ──────────────────────────────────────────────────────
;  Hauptschleife
;  HotKeySet setzt ein Flag (_OnHotkey), die Schleife
;  reagiert darauf – kein GUIRegisterMsg, kein DllCall nötig.
; ──────────────────────────────────────────────────────
While True
    ; ── Hotkey-Flag auswerten ──
    If $g_TogglePending Then
        $g_TogglePending = False
        _Overlay_Toggle()
    EndIf

    ; ── Tray ──
    Local $tMsg = TrayGetMsg()
    Switch $tMsg
        Case $g_TI_Reload
            _Config_Load()
            _Hotkey_Set()
            _Buttons_LoadAll()
            _List_Refresh(GUICtrlRead($g_hInput))
            TrayTip($APP_NAME, UBound($g_Buttons) & " Buttons geladen.", 2)
        Case $g_TI_Settings
            ShellExecute($g_ConfigPath)
        Case $g_TI_Exit
            ExitLoop
    EndSwitch

    ; ── GUI ──
    Local $gMsg = GUIGetMsg()
    Switch $gMsg
        Case $GUI_EVENT_CLOSE
            _Overlay_Hide()
    EndSwitch

    ; ── Tastatur (nur wenn Overlay sichtbar & aktiv) ──
    If BitAND(WinGetState($g_hGUI), 2) Then
        If Not WinActive($g_hGUI) Then
            _Overlay_Hide()
        Else
            If _KeyDown(0x0D) Then      ; Enter
                _RunSelected()
                _WaitRelease(0x0D)
            ElseIf _KeyDown(0x1B) Then  ; Escape
                _Overlay_Hide()
                _WaitRelease(0x1B)
            ElseIf _KeyDown(0x26) Then  ; Pfeil hoch
                _ListMove(-1)
                _WaitRelease(0x26)
            ElseIf _KeyDown(0x28) Then  ; Pfeil runter
                _ListMove(1)
                _WaitRelease(0x28)
            EndIf
        EndIf
    EndIf

    Sleep(20)
WEnd

HotKeySet($g_HotKeyStr)   ; Hotkey deregistrieren
GUIDelete($g_hGUI)
Exit

; ══════════════════════════════════════════════════════
;  HOTKEY – AutoIt HotKeySet
;  Vorteil gegenüber RegisterHotKey/GUIRegisterMsg:
;  - kein Windows-Message-Routing nötig
;  - funktioniert systemweit ohne hwnd
;  - Callback wird direkt von AutoIt aufgerufen
;  WICHTIG: Der Callback darf KEIN Blocking (MsgBox etc.)
;  enthalten. Daher nur ein Flag setzen, die Hauptschleife
;  macht die eigentliche Arbeit.
; ══════════════════════════════════════════════════════
Func _Hotkey_Set()
    ; Alten Hotkey erst abmelden
    HotKeySet($g_HotKeyStr)

    ; Hotkey-String aus Config neu aufbauen
    Local $mod = _IniReadInt("hotkey_mod", 2)
    Local $vk  = _IniReadInt("hotkey_vk",  32)
    $g_HotKeyStr = _BuildHotkeyStr($mod, $vk)

    Local $ret = HotKeySet($g_HotKeyStr, "_OnHotkey")
    If @error Or $ret = 0 Then
        TrayTip($APP_NAME, "Hotkey '" & _HotkeyStrReadable($g_HotKeyStr) & "' konnte nicht gesetzt werden." & @CRLF & _
            "Bitte config.ini prüfen oder den Hotkey in anderen Programmen deaktivieren.", 5)
    Else
        TrayTip($APP_NAME, "Hotkey gesetzt: " & _HotkeyStrReadable($g_HotKeyStr), 2)
    EndIf
EndFunc

; Callback – wird von AutoIt direkt beim Tastendruck aufgerufen.
; NUR Flag setzen, kein GUI-Code hier!
Func _OnHotkey()
    If $g_TCOnly Then
        Local $hFG = WinGetHandle("[ACTIVE]")
        If $hFG <> "" Then
            Local $cls = _WinAPI_GetClassName($hFG)
            If $cls <> $TC_CLASS_32 And $cls <> $TC_CLASS_64 Then Return
        EndIf
    EndIf
    $g_TogglePending = True
EndFunc

; Baut einen AutoIt-HotKeySet-String aus Modifier-Bitmask und VK-Code.
; Modifier: 1=Alt, 2=Ctrl, 4=Shift, 8=Win  (kombinierbar)
; VK→AutoIt: Space={SPACE}, F1-F12={F1}…{F12}, Buchstaben direkt
Func _BuildHotkeyStr($mod, $vk)
    Local $prefix = ""
    If BitAND($mod, 8) Then $prefix &= "#"   ; Win
    If BitAND($mod, 2) Then $prefix &= "^"   ; Ctrl
    If BitAND($mod, 1) Then $prefix &= "!"   ; Alt
    If BitAND($mod, 4) Then $prefix &= "+"   ; Shift

    Local $key = ""
    Switch $vk
        Case 0x08 ; Backspace
            $key = "{BS}"
        Case 0x09 ; Tab
            $key = "{TAB}"
        Case 0x0D ; Enter
            $key = "{ENTER}"
        Case 0x1B ; Escape
            $key = "{ESC}"
        Case 0x20 ; Space
            $key = "{SPACE}"
        Case 0x21 ; Page Up
            $key = "{PGUP}"
        Case 0x22 ; Page Down
            $key = "{PGDN}"
        Case 0x23 ; End
            $key = "{END}"
        Case 0x24 ; Home
            $key = "{HOME}"
        Case 0x25 ; Left
            $key = "{LEFT}"
        Case 0x26 ; Up
            $key = "{UP}"
        Case 0x27 ; Right
            $key = "{RIGHT}"
        Case 0x28 ; Down
            $key = "{DOWN}"
        Case 0x2E ; Delete
            $key = "{DEL}"
        Case 0x70 To 0x7B ; F1–F12
            $key = "{F" & ($vk - 0x70 + 1) & "}"
        Case 0x30 To 0x39 ; 0–9
            $key = Chr($vk)
        Case 0x41 To 0x5A ; A–Z
            $key = Chr($vk)
        Case Else
            $key = Chr($vk)  ; Fallback – funktioniert für druckbare ASCII-Zeichen
    EndSwitch

    Return $prefix & $key
EndFunc

; Wandelt AutoIt-Hotkey-String (z.B. "^{SPACE}") in lesbaren Text um (z.B. "Ctrl+Space").
; Modifier werden zuerst aus dem Präfix extrahiert, dann die Taste separat übersetzt –
; so wird "+" nie mit dem bereits erzeugten "Ctrl+" verwechselt.
Func _HotkeyStrReadable($hk)
    Local $prefix = ""
    Local $rest   = $hk

    ; Modifier-Zeichen vom Anfang ablesen und konsumieren
    Local $continue = True
    While $continue
        Local $first = StringLeft($rest, 1)
        Switch $first
            Case "^"
                $prefix &= "Ctrl+"
                $rest = StringTrimLeft($rest, 1)
            Case "!"
                $prefix &= "Alt+"
                $rest = StringTrimLeft($rest, 1)
            Case "+"
                $prefix &= "Shift+"
                $rest = StringTrimLeft($rest, 1)
            Case "#"
                $prefix &= "Win+"
                $rest = StringTrimLeft($rest, 1)
            Case Else
                $continue = False
        EndSwitch
    WEnd

    ; Tastenname übersetzen
    Local $key = $rest
    $key = StringReplace($key, "{SPACE}",  "Space")
    $key = StringReplace($key, "{ENTER}",  "Enter")
    $key = StringReplace($key, "{ESC}",    "Escape")
    $key = StringReplace($key, "{TAB}",    "Tab")
    $key = StringReplace($key, "{BS}",     "Backspace")
    $key = StringReplace($key, "{DEL}",    "Delete")
    $key = StringReplace($key, "{INS}",    "Insert")
    $key = StringReplace($key, "{HOME}",   "Home")
    $key = StringReplace($key, "{END}",    "End")
    $key = StringReplace($key, "{PGUP}",   "Page Up")
    $key = StringReplace($key, "{PGDN}",   "Page Down")
    $key = StringReplace($key, "{UP}",     "Up")
    $key = StringReplace($key, "{DOWN}",   "Down")
    $key = StringReplace($key, "{LEFT}",   "Left")
    $key = StringReplace($key, "{RIGHT}",  "Right")
    $key = StringReplace($key, "{F1}",     "F1")
    $key = StringReplace($key, "{F2}",     "F2")
    $key = StringReplace($key, "{F3}",     "F3")
    $key = StringReplace($key, "{F4}",     "F4")
    $key = StringReplace($key, "{F5}",     "F5")
    $key = StringReplace($key, "{F6}",     "F6")
    $key = StringReplace($key, "{F7}",     "F7")
    $key = StringReplace($key, "{F8}",     "F8")
    $key = StringReplace($key, "{F9}",     "F9")
    $key = StringReplace($key, "{F10}",    "F10")
    $key = StringReplace($key, "{F11}",    "F11")
    $key = StringReplace($key, "{F12}",    "F12")
    ; Verbleibende geschweifte Klammern entfernen
    $key = StringRegExpReplace($key, "[{}]", "")

    Return $prefix & $key
EndFunc

; ══════════════════════════════════════════════════════
;  TRAY
; ══════════════════════════════════════════════════════
Func _Tray_Build()
    Opt("TrayMenuMode", 1)
    Opt("TrayOnEventMode", 0)
    TraySetToolTip($APP_NAME)
    ; app.ico aus dem Programmverzeichnis verwenden wenn vorhanden
    If FileExists($ICON_FILE) Then
        TraySetIcon($ICON_FILE)
    EndIf
    $g_TI_Reload   = TrayCreateItem("Reload Bars && config")
    $g_TI_Settings = TrayCreateItem("Settings (config.ini öffnen)")
    TrayCreateItem("")
    $g_TI_Exit     = TrayCreateItem("Exit")
    TraySetState($TRAY_ICONSTATE_SHOW)
EndFunc

; ══════════════════════════════════════════════════════
;  KONFIGURATION
; ══════════════════════════════════════════════════════
Func _Config_Load()
    If Not FileExists($g_ConfigPath) Then _Config_WriteDefaults()
    ; tc_path kann Verzeichnis ODER Pfad zur EXE sein – wir normalisieren auf Verzeichnis
    Local $rawTCPath = IniRead($g_ConfigPath, "App", "tc_path", _TC_FindPath())
    $g_TCPath = _NormalizeTCPath($rawTCPath)
    $g_TCOnly  = _IniReadBool("tc_only",   True)
    $g_WinW    = _IniReadInt("window_width",  660)
    $g_WinH    = _IniReadInt("window_height", 440)
    $g_WinX    = _IniReadInt("window_x",      -1)
    $g_WinY       = _IniReadInt("window_y",      -1)
    $g_MaxResults = _IniReadInt("max_results",  200)
EndFunc

Func _Config_WriteDefaults()
    IniWrite($g_ConfigPath, "App", "tc_path",       _TC_FindPath())
    IniWrite($g_ConfigPath, "App", "tc_only",       "true")
    IniWrite($g_ConfigPath, "App", "hotkey_mod",    "2")
    IniWrite($g_ConfigPath, "App", "hotkey_vk",     "32")
    IniWrite($g_ConfigPath, "App", "window_width",  "660")
    IniWrite($g_ConfigPath, "App", "window_height", "440")
    IniWrite($g_ConfigPath, "App", "window_x",      "-1")
    IniWrite($g_ConfigPath, "App", "window_y",      "-1")
    IniWrite($g_ConfigPath, "App", "max_results",  "200")
EndFunc

Func _IniReadBool($key, $default)
    Local $v = StringLower(StringStripWS(IniRead($g_ConfigPath, "App", $key, $default ? "true" : "false"), 3))
    Return ($v = "1" Or $v = "true" Or $v = "yes" Or $v = "on")
EndFunc

Func _IniReadInt($key, $default)
    Local $v = StringStripWS(IniRead($g_ConfigPath, "App", $key, String($default)), 3)
    If StringLeft(StringLower($v), 2) = "0x" Then Return Dec(StringTrimLeft($v, 2))
    Return Int(Number($v))
EndFunc

Func _TC_FindPath()
    Local $v = RegRead("HKEY_CURRENT_USER\Software\Ghisler\Total Commander", "InstallDir")
    If Not @error And FileExists($v) Then Return $v
    $v = RegRead("HKEY_CURRENT_USER\Software\Ghisler\Total Commander", "IniFileName")
    If Not @error And FileExists($v) Then Return StringRegExpReplace($v, "\\[^\\]+$", "")
    If FileExists("C:\totalcmd64") Then Return "C:\totalcmd64"
    If FileExists("C:\totalcmd")   Then Return "C:\totalcmd"
    Return @AppDataDir
EndFunc

; Normalisiert tc_path: akzeptiert Verzeichnis ODER Pfad zur EXE
Func _NormalizeTCPath($raw)
    $raw = StringStripWS($raw, 3)
    If $raw = "" Then Return _TC_FindPath()
    ; Wenn es auf .exe endet → Verzeichnis extrahieren
    If StringRight(StringLower($raw), 4) = ".exe" Then
        Local $slash = StringInStr($raw, "\", 0, -1)
        If $slash > 1 Then Return StringLeft($raw, $slash - 1)
    EndIf
    ; Sonst: direkt als Verzeichnis verwenden
    Return $raw
EndFunc

; ══════════════════════════════════════════════════════
;  PARSER
; ══════════════════════════════════════════════════════
Func _Buttons_LoadAll()
    ReDim $g_Buttons[0][6]
    Local $files = _Bar_FindFiles($g_TCPath)
    For $i = 0 To UBound($files) - 1
        _Bar_Parse($files[$i])
    Next
EndFunc

Func _Bar_FindFiles($tcp)
    Local $out[0]
    If Not FileExists($tcp) Then Return $out
    Local $wincmd = $tcp & "\wincmd.ini"
    If Not FileExists($wincmd) Then $wincmd = $tcp & "\WINCMD.INI"
    If FileExists($wincmd) Then
        Local $secs = IniReadSectionNames($wincmd)
        If Not @error Then
            For $i = 1 To $secs[0]
                Local $arr = IniReadSection($wincmd, $secs[$i])
                If @error Then ContinueLoop
                For $j = 1 To $arr[0][0]
                    If StringRight(StringLower($arr[$j][1]), 4) = ".bar" Then
                        Local $c = $arr[$j][1]
                        If StringMid($c, 2, 1) <> ":" And StringLeft($c, 2) <> "\\" Then $c = $tcp & "\" & $c
                        _ArrAddUnique($out, $c)
                    EndIf
                Next
            Next
        EndIf
    EndIf
    Local $found = _FileListToArrayRec($tcp, "*.bar", $FLTAR_FILES, $FLTAR_RECUR, $FLTAR_NOSORT, $FLTAR_FULLPATH)
    If Not @error Then
        For $i = 1 To $found[0]
            _ArrAddUnique($out, $found[$i])
        Next
    EndIf
    Return $out
EndFunc

Func _Bar_Parse($barpath)
    Local $n = _IniFileInt($barpath, "Buttonbar", "Buttoncount", 0)
    If $n <= 0 Then Return
    Local $barname = StringTrimRight(StringTrimLeft($barpath, StringInStr($barpath, "\", 0, -1)), 4)
    For $i = 1 To $n
        Local $cmd = StringStripWS(IniRead($barpath, "Buttonbar", "cmd" & $i, ""), 3)
        If $cmd = "" Then ContinueLoop
        Local $admin = False
        If StringLeft($cmd, 1) = ">" Then
            $admin = True
            $cmd = StringTrimLeft($cmd, 1)
        EndIf
        If StringRight(StringLower($cmd), 4) = ".bar" Then ContinueLoop
        Local $menu  = StringStripWS(IniRead($barpath, "Buttonbar", "menu"  & $i, ""), 3)
        Local $param = StringStripWS(IniRead($barpath, "Buttonbar", "param" & $i, ""), 3)
        Local $path  = StringStripWS(IniRead($barpath, "Buttonbar", "path"  & $i, ""), 3)
        _Btn_Add($menu, $cmd, $param, $path, $barname, $admin)
    Next
EndFunc

Func _IniFileInt($file, $sec, $key, $def)
    Local $v = StringStripWS(IniRead($file, $sec, $key, String($def)), 3)
    If StringLeft(StringLower($v), 2) = "0x" Then Return Dec(StringTrimLeft($v, 2))
    Return Int(Number($v))
EndFunc

Func _Btn_Add($menu, $cmd, $param, $workdir, $bar, $admin)
    Local $i = UBound($g_Buttons)
    ReDim $g_Buttons[$i + 1][6]
    $g_Buttons[$i][0] = $menu
    $g_Buttons[$i][1] = $cmd
    $g_Buttons[$i][2] = $param
    $g_Buttons[$i][3] = $workdir
    $g_Buttons[$i][4] = $bar
    $g_Buttons[$i][5] = $admin
EndFunc

; ══════════════════════════════════════════════════════
;  GUI – Overlay
; ══════════════════════════════════════════════════════
Func _GUI_Build()
    $g_hGUI = GUICreate($APP_NAME, $g_WinW, $g_WinH, -1, -1, _
        BitOR($WS_POPUP, $WS_BORDER), _
        BitOR($WS_EX_TOPMOST, $WS_EX_TOOLWINDOW))
    GUISetBkColor(0x1E1E2E, $g_hGUI)
    GUISetFont(11, 400, 0, "Segoe UI", $g_hGUI)  ; Basis: 9px + 2px = 11px

    $g_hInput = GUICtrlCreateInput("", 10, 10, $g_WinW - 20, 28)
    GUICtrlSetBkColor($g_hInput, 0x313244)
    GUICtrlSetColor($g_hInput, 0xCDD6F4)


    ; Custom-Hint-Label: liegt über dem Input, gleiche Position/Größe
    ; Hintergrundfarbe = Input-Hintergrund, Textfarbe etwas heller als Muted
    $g_hHint = GUICtrlCreateLabel("Search button bars... (regex)", 14, 14, $g_WinW - 28, 20)
    GUICtrlSetBkColor($g_hHint, 0x313244)
    GUICtrlSetColor($g_hHint, 0x7A8099)   ; gedimmtes Grau-Blau (~20% heller als Muted)
    GUICtrlSetFont($g_hHint, 11, 400, 0, "Segoe UI")

    $g_hList = GUICtrlCreateListView("Name|Command / Params|Bar", 10, 48, $g_WinW - 20, $g_WinH - 86, _
        BitOR($LVS_SHOWSELALWAYS, $LVS_SINGLESEL))
    _GUICtrlListView_SetColumnWidth($g_hList, 0, 220)
    _GUICtrlListView_SetColumnWidth($g_hList, 1, 320)
    _GUICtrlListView_SetColumnWidth($g_hList, 2, 90)

    $g_hStatus = GUICtrlCreateLabel("", 10, $g_WinH - 30, $g_WinW - 20, 20, $SS_RIGHT)
    GUICtrlSetColor($g_hStatus, 0xA6ADC8)

    GUIRegisterMsg($WM_COMMAND, "_WM_COMMAND")

    _List_Refresh("")
    GUISetState(@SW_HIDE, $g_hGUI)
EndFunc

Func _Overlay_Show()
    Local $x = $g_WinX, $y = $g_WinY
    If $x < 0 Or $y < 0 Then
        Local $hTC = _TC_GetHwnd()
        If $hTC <> "" Then
            Local $tc = WinGetPos($hTC)
            If IsArray($tc) Then
                $x = $tc[0] + Int(($tc[2] - $g_WinW) / 2)
                $y = $tc[1] + 80
            EndIf
        EndIf
        If $x < 0 Or $y < 0 Then
            $x = Int((@DesktopWidth  - $g_WinW) / 2)
            $y = Int((@DesktopHeight - $g_WinH) / 3)
        EndIf
    EndIf
    WinMove($g_hGUI, "", $x, $y, $g_WinW, $g_WinH)
    GUICtrlSetData($g_hInput, "")
    GUICtrlSetState($g_hHint, $GUI_SHOW)  ; Hint beim Öffnen immer anzeigen
    _List_Refresh("")
    GUISetState(@SW_SHOW, $g_hGUI)
    WinActivate($g_hGUI)
    ControlFocus($g_hGUI, "", $g_hInput)
EndFunc

Func _Overlay_Hide()
    GUISetState(@SW_HIDE, $g_hGUI)
    Local $hTC = _TC_GetHwnd()
    If $hTC <> "" Then WinActivate($hTC)
EndFunc

Func _Overlay_Toggle()
    If BitAND(WinGetState($g_hGUI), 2) Then
        _Overlay_Hide()
    Else
        _Overlay_Show()
    EndIf
EndFunc

Func _List_Refresh($filter)
    Local $hLV = GUICtrlGetHandle($g_hList)

    ; Flackern unterdrücken: Neuzeichnen des ListView deaktivieren
    _SendMessage($hLV, $WM_SETREDRAW, False)

    _GUICtrlListView_DeleteAllItems($g_hList)
    ReDim $g_CurrentRows[0]
    Local $needle = StringLower($filter)
    Local $resultCount = 0
    For $i = 0 To UBound($g_Buttons) - 1
        If $resultCount >= $g_MaxResults Then ExitLoop
        Local $hay = StringLower($g_Buttons[$i][0] & " " & $g_Buttons[$i][1] & " " & $g_Buttons[$i][2])
        Local $match = ($needle = "") Or (StringInStr($hay, $needle) > 0)
        If Not $match And $filter <> "" Then
            $match = (StringRegExp($hay, $filter) = 1)
            If @error Then $match = False
        EndIf
        If $match Then
            GUICtrlCreateListViewItem( _
                $g_Buttons[$i][0] & "|" & _
                $g_Buttons[$i][1] & " " & $g_Buttons[$i][2] & "|" & _
                $g_Buttons[$i][4], $g_hList)
            _ArrayAdd($g_CurrentRows, $i)
            $resultCount += 1
        EndIf
    Next
    If _GUICtrlListView_GetItemCount($g_hList) > 0 Then
        _GUICtrlListView_SetItemSelected($g_hList, 0, True, True)
    EndIf

    ; Neuzeichnen wieder aktivieren und einmalig sauber neu zeichnen
    _SendMessage($hLV, $WM_SETREDRAW, True)
    DllCall("user32.dll", "bool", "RedrawWindow", _
        "hwnd", $hLV, _
        "ptr",  0, _
        "ptr",  0, _
        "uint", 0x0085)  ; RDW_ERASE | RDW_FRAME | RDW_INVALIDATE | RDW_ALLCHILDREN → 0x85

    GUICtrlSetData($g_hStatus, _GUICtrlListView_GetItemCount($g_hList) & " of " & UBound($g_Buttons) & " buttons")
EndFunc

Func _ListMove($delta)
    Local $cnt = _GUICtrlListView_GetItemCount($g_hList)
    If $cnt = 0 Then Return
    Local $idx = _GUICtrlListView_GetNextItem($g_hList)
    If $idx < 0 Then $idx = 0
    $idx += $delta
    If $idx < 0     Then $idx = 0
    If $idx >= $cnt Then $idx = $cnt - 1
    _GUICtrlListView_SetItemSelected($g_hList, -1, False, False)
    _GUICtrlListView_SetItemSelected($g_hList, $idx, True, True)
    _GUICtrlListView_EnsureVisible($g_hList, $idx)
EndFunc

Func _WM_COMMAND($hWnd, $Msg, $wParam, $lParam)
    Local $ctrl   = BitAND($wParam, 0xFFFF)
    Local $notify = BitShift($wParam, 16)

    If $ctrl = $g_hInput Then
        Switch $notify
            Case $EN_CHANGE
                _List_Refresh(GUICtrlRead($g_hInput))
                ; Hint ausblenden sobald Text vorhanden
                If GUICtrlRead($g_hInput) <> "" Then
                    GUICtrlSetState($g_hHint, $GUI_HIDE)
                Else
                    GUICtrlSetState($g_hHint, $GUI_SHOW)
                EndIf
            Case $EN_SETFOCUS   ; Fokus erhalten → Hint nur verstecken wenn bereits Text drin
                If GUICtrlRead($g_hInput) <> "" Then
                    GUICtrlSetState($g_hHint, $GUI_HIDE)
                EndIf
            Case $EN_KILLFOCUS  ; Fokus verloren → Hint nur zeigen wenn leer
                If GUICtrlRead($g_hInput) = "" Then
                    GUICtrlSetState($g_hHint, $GUI_SHOW)
                EndIf
        EndSwitch
    EndIf
    Return $GUI_RUNDEFMSG
EndFunc

; ══════════════════════════════════════════════════════
;  EXECUTOR
; ══════════════════════════════════════════════════════
Func _RunSelected()
    Local $idx = _GUICtrlListView_GetNextItem($g_hList)
    If $idx < 0 Or $idx >= UBound($g_CurrentRows) Then Return
    _Btn_Execute($g_CurrentRows[$idx])
    _Overlay_Hide()
EndFunc

Func _Btn_Execute($bi)
    Local $cmd     = _EnvReplace($g_Buttons[$bi][1])
    Local $param   = _EnvReplace($g_Buttons[$bi][2])
    Local $workdir = _EnvReplace($g_Buttons[$bi][3])
    Local $admin   = $g_Buttons[$bi][5]
    If $workdir <> "" And Not FileExists($workdir) Then $workdir = ""
    If StringLeft(StringLower($cmd), 2) = "cm" Or StringLeft(StringLower($cmd), 2) = "em" Then
        _TC_RunInternal($cmd, $param)
        Return
    EndIf
    If $admin Then
        ShellExecute($cmd, $param, $workdir, "runas")
    Else
        ShellExecute($cmd, $param, $workdir)
    EndIf
EndFunc

Func _TC_RunInternal($cmd, $param)
    Local $exe = ""
    If FileExists($g_TCPath & "\TOTALCMD64.EXE") Then $exe = $g_TCPath & "\TOTALCMD64.EXE"
    If $exe = "" And FileExists($g_TCPath & "\TOTALCMD.EXE") Then $exe = $g_TCPath & "\TOTALCMD.EXE"
    If $exe <> "" Then
        Run('"' & $exe & '" /O /S /C' & $cmd & ($param <> "" ? " " & $param : ""), "", @SW_HIDE)
        Return
    EndIf
    Local $hTC = _TC_GetHwnd()
    If $hTC = "" Then Return
    Local $pl = $cmd & ($param <> "" ? " " & $param : "")
    Local $tD = DllStructCreate("char[" & (StringLen($pl) + 2) & "]")
    DllStructSetData($tD, 1, $pl)
    Local $tC = DllStructCreate($tagCDS)
    DllStructSetData($tC, "dwData", $EM_COMMAND_DW)
    DllStructSetData($tC, "cbData", StringLen($pl) + 1)
    DllStructSetData($tC, "lpData", DllStructGetPtr($tD))
    _SendMessage($hTC, $WM_COPYDATA_MSG, 0, DllStructGetPtr($tC), 0, "wparam", "ptr")
EndFunc

Func _TC_GetHwnd()
    Local $h = WinGetHandle("[CLASS:" & $TC_CLASS_64 & "]")
    If $h <> "" Then Return $h
    Return WinGetHandle("[CLASS:" & $TC_CLASS_32 & "]")
EndFunc

; ══════════════════════════════════════════════════════
;  HILFSFUNKTIONEN
; ══════════════════════════════════════════════════════
Func _EnvReplace($s)
    $s = StringReplace($s, "%COMMANDER_PATH%", $g_TCPath)
    $s = StringReplace($s, "%COMMANDERPATH%",  $g_TCPath)
    Local $m = StringRegExp($s, "%([A-Za-z0-9_]+)%", 3)
    If IsArray($m) Then
        For $i = 0 To UBound($m) - 1
            $s = StringReplace($s, "%" & $m[$i] & "%", EnvGet($m[$i]))
        Next
    EndIf
    Return $s
EndFunc

Func _ArrAddUnique(ByRef $arr, $v)
    For $i = 0 To UBound($arr) - 1
        If $arr[$i] = $v Then Return
    Next
    _ArrayAdd($arr, $v)
EndFunc

Func _KeyDown($vk)
    Local $r = DllCall("user32.dll", "short", "GetAsyncKeyState", "int", $vk)
    If @error Or Not IsArray($r) Then Return False
    Return BitAND($r[0], 0x8000) <> 0
EndFunc

Func _WaitRelease($vk)
    While _KeyDown($vk)
        Sleep(20)
    WEnd
EndFunc
