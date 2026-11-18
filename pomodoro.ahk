#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
SetWorkingDir(A_ScriptDir)

; ============================================================================
; Pomodoro for Windows 11 - single-file AutoHotkey v2 application
; Local-only data in %AppData%\PomodoroApp. No network access is used.
; ============================================================================

if (A_Args.Length > 0 && A_Args[1] = "--selftest")
{
    RunSelfTest()
    ExitApp
}

OnExit(AppExitHandler)

Store.Init()
SoundScaler.Init(Store.Dir)
TimerEngine.Init()
SetupTray()
MainUI.Build()
MainUI.ShowInitial()
ApplyLiveSettings()

; ============================================================================
; Small, dependency-free helpers
; ============================================================================

AtomicWriteText(Path, Text)
{
    ; Write a sibling temp file, flush it, then replace the original in one move.
    tmp := Path ".tmp"
    try
    {
        SplitPath(Path, , &dir)
        if (dir != "")
            DirCreate(dir)
        if FileExist(tmp)
            FileDelete(tmp)
        f := FileOpen(tmp, "w", "UTF-8-RAW")
        f.Write(Text)
        f.Close()
        FileMove(tmp, Path, 1)
        return true
    }
    catch
    {
        try
        {
            if IsSet(f)
                f.Close()
        }
        try
        {
            if FileExist(tmp)
                FileDelete(tmp)
        }
        return false
    }
}

ReadTextFile(Path, Default := "")
{
    if !FileExist(Path)
        return Default
    try
        return FileRead(Path, "UTF-8")
    catch
        return Default
}

ToInt(Value, Default := 0)
{
    s := Trim("" Value)
    if RegExMatch(s, "^-?\d+$")
        return s + 0
    return Default
}

ClampInt(Value, MinValue, MaxValue, Default)
{
    n := ToInt(Value, Default)
    if (n < MinValue)
        n := MinValue
    if (n > MaxValue)
        n := MaxValue
    return n
}

IniReadString(File, Section, Key, Default)
{
    try
    {
        v := IniRead(File, Section, Key, Default)
        return (v = "" && Default != "") ? Default : v
    }
    catch
        return Default
}

IniReadInt(File, Section, Key, Default, MinValue, MaxValue)
{
    return ClampInt(IniReadString(File, Section, Key, Default), MinValue, MaxValue, Default)
}

IniValue(Value)
{
    ; INI values must stay on one line.
    return StrReplace(StrReplace("" Value, "`r", " "), "`n", " ")
}

EscapeField(Value)
{
    ; Tab-separated storage with a simple, reversible backslash escaping.
    s := "" Value
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, "`t", "\t")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    return s
}

UnescapeField(Value)
{
    s := "" Value
    out := ""
    i := 1
    n := StrLen(s)
    while (i <= n)
    {
        ch := SubStr(s, i, 1)
        if (ch != "\")
        {
            out .= ch
            i += 1
            continue
        }
        i += 1
        if (i > n)
        {
            out .= "\"
            break
        }
        esc := SubStr(s, i, 1)
        if (esc = "n")
            out .= "`n"
        else if (esc = "r")
            out .= "`r"
        else if (esc = "t")
            out .= "`t"
        else if (esc = "\")
            out .= "\"
        else
            out .= esc
        i += 1
    }
    return out
}

CsvField(Value)
{
    s := "" Value
    if InStr(s, '"') || InStr(s, ",") || InStr(s, "`n") || InStr(s, "`r")
        return '"' . StrReplace(s, '"', '""') . '"'
    return s
}

ParseCsv(Text)
{
    ; Hand-written RFC-4180-style parser. Handles quoted commas, quotes and
    ; newlines without any external library.
    records := []
    row := []
    field := ""
    inQuotes := false
    i := 1
    n := StrLen(Text)
    while (i <= n)
    {
        ch := SubStr(Text, i, 1)
        if inQuotes
        {
            if (ch = '"')
            {
                if (SubStr(Text, i + 1, 1) = '"')
                {
                    field .= '"'
                    i += 2
                    continue
                }
                inQuotes := false
                i += 1
                continue
            }
            field .= ch
            i += 1
            continue
        }

        if (ch = '"')
        {
            inQuotes := true
        }
        else if (ch = ",")
        {
            row.Push(field)
            field := ""
        }
        else if (ch = "`n")
        {
            row.Push(field)
            records.Push(row)
            row := []
            field := ""
        }
        else if (ch != "`r")
        {
            field .= ch
        }
        i += 1
    }
    if (field != "" || row.Length > 0)
    {
        row.Push(field)
        records.Push(row)
    }
    return records
}

CloneMap(Source)
{
    out := Map()
    for k, v in Source
        out[k] := v
    return out
}

SortUniqueStrings(Items)
{
    text := ""
    seen := Map()
    for item in Items
    {
        s := Trim("" item)
        if (s = "")
            continue
        key := StrLower(s)
        if seen.Has(key)
            continue
        seen[key] := true
        text .= s "`n"
    }
    if (text = "")
        return []
    text := Sort(text, "U")
    out := []
    for line in StrSplit(text, "`n", "`r")
    {
        if (line != "")
            out.Push(line)
    }
    return out
}

FormatDuration(Minutes)
{
    m := Max(0, Round(Minutes))
    h := m // 60
    r := Mod(m, 60)
    if (h > 0)
        return h "h " r "m"
    return r "m"
}

MenuText(Value)
{
    ; Avoid interpreting ampersands in user text as menu accelerators.
    s := StrReplace("" Value, "`t", " ")
    return StrReplace(s, "&", "&&")
}

ClampWindowToScreen(&X, &Y, Width, Height)
{
    ; Keep at least a useful part of the title bar on a real monitor. Any
    ; monitor counts, including a secondary monitor with negative coordinates.
    try
    {
        count := MonitorGetCount()
        Loop count
        {
            MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
            ix := Min(X + Width, r) - Max(X, l)
            iy := Min(Y + Height, b) - Max(Y, t)
            if (ix >= 100 && iy >= 40)
                return
        }
        MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    }
    catch
    {
        l := 0
        t := 0
        r := A_ScreenWidth
        b := A_ScreenHeight
    }
    X := Max(l, Min(X, r - Width))
    Y := Max(t, Min(Y, b - Height))
}

DaysInMonth(Year, Month)
{
    static lengths := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if (Month < 1 || Month > 12)
        return 30
    if (Month = 2 && Mod(Year, 4) = 0 && (Mod(Year, 100) != 0 || Mod(Year, 400) = 0))
        return 29
    return lengths[Month]
}

; ============================================================================
; Persistent data store
; ============================================================================

class Store
{
    static Dir := ""
    static SettingsFile := ""
    static TasksFile := ""
    static HistoryFile := ""
    static Settings := Map()
    static Tasks := []
    static Projects := []
    static Templates := []
    static History := []
    static ActiveTaskId := 0
    static NextTaskId := 1
    static NextTemplateId := 1

    static Init(DirOverride := "")
    {
        this.Dir := (DirOverride != "") ? DirOverride : (A_AppData "\PomodoroApp")
        this.SettingsFile := this.Dir "\settings.ini"
        this.TasksFile := this.Dir "\tasks.tsv"
        this.HistoryFile := this.Dir "\history.csv"
        try DirCreate(this.Dir)
        this.SetDefaults()
        this.LoadSettings()
        this.LoadTasks()
        this.LoadHistory()
        this.ValidateActiveTask()
    }

    static SetDefaults()
    {
        this.Settings := Map(
            "Pomodoro", 25,
            "ShortBreak", 5,
            "LongBreak", 15,
            "AutoStartBreaks", 0,
            "AutoStartPomodoros", 0,
            "LongBreakInterval", 4,
            "AutoSwitchTask", 0,
            "CloseToTray", 1,
            "AlwaysOnTop", 0,
            "TimeFormat", "24h",
            "DarkWhenRunning", 0,
            "AlarmSound", A_WinDir "\Media\Alarm01.wav",
            "AlarmVolume", 70,
            "AlarmRepeat", 1,
            "Ticking", 0,
            "TickSpeed", 1,
            "TickVolume", 60,
            "ReminderEnabled", 0,
            "ReminderType", "BeforeEnd",
            "ReminderMinutes", 5,
            "LastMode", "Pomodoro",
            "ActiveTaskId", 0,
            "WinX", "",
            "WinY", ""
        )
        this.Tasks := []
        this.Projects := []
        this.Templates := []
        this.History := []
        this.ActiveTaskId := 0
        this.NextTaskId := 1
        this.NextTemplateId := 1
    }

    static Get(Key, Default := "")
    {
        return this.Settings.Has(Key) ? this.Settings[Key] : Default
    }

    static Set(Key, Value)
    {
        this.Settings[Key] := Value
    }

    static LoadSettings()
    {
        f := this.SettingsFile
        if !FileExist(f)
        {
            this.SaveSettings()
            return
        }

        this.Settings["Pomodoro"] := IniReadInt(f, "Timer", "Pomodoro", 25, 1, 180)
        this.Settings["ShortBreak"] := IniReadInt(f, "Timer", "ShortBreak", 5, 1, 60)
        this.Settings["LongBreak"] := IniReadInt(f, "Timer", "LongBreak", 15, 1, 120)
        this.Settings["LongBreakInterval"] := IniReadInt(f, "Timer", "LongBreakInterval", 4, 1, 12)

        this.Settings["AutoStartBreaks"] := IniReadInt(f, "Behavior", "AutoStartBreaks", 0, 0, 1)
        this.Settings["AutoStartPomodoros"] := IniReadInt(f, "Behavior", "AutoStartPomodoros", 0, 0, 1)
        this.Settings["AutoSwitchTask"] := IniReadInt(f, "Behavior", "AutoSwitchTask", 0, 0, 1)
        this.Settings["CloseToTray"] := IniReadInt(f, "Behavior", "CloseToTray", 1, 0, 1)
        this.Settings["AlwaysOnTop"] := IniReadInt(f, "Behavior", "AlwaysOnTop", 0, 0, 1)
        this.Settings["DarkWhenRunning"] := IniReadInt(f, "Behavior", "DarkWhenRunning", 0, 0, 1)

        tf := IniReadString(f, "Behavior", "TimeFormat", "24h")
        this.Settings["TimeFormat"] := (tf = "12h") ? "12h" : "24h"

        alarm := IniReadString(f, "Alarm", "Sound", A_WinDir "\Media\Alarm01.wav")
        if !FileExist(alarm)
            alarm := A_WinDir "\Media\Alarm01.wav"
        this.Settings["AlarmSound"] := alarm
        this.Settings["AlarmVolume"] := IniReadInt(f, "Alarm", "Volume", 70, 0, 100)
        this.Settings["AlarmRepeat"] := IniReadInt(f, "Alarm", "Repeat", 1, 1, 5)

        this.Settings["Ticking"] := IniReadInt(f, "Tick", "Enabled", 0, 0, 1)
        this.Settings["TickSpeed"] := IniReadInt(f, "Tick", "Speed", 1, 1, 3)
        this.Settings["TickVolume"] := IniReadInt(f, "Tick", "Volume", 60, 0, 100)

        this.Settings["ReminderEnabled"] := IniReadInt(f, "Reminder", "Enabled", 0, 0, 1)
        rt := IniReadString(f, "Reminder", "Type", "BeforeEnd")
        this.Settings["ReminderType"] := (rt = "AfterStart") ? "AfterStart" : "BeforeEnd"
        this.Settings["ReminderMinutes"] := IniReadInt(f, "Reminder", "Minutes", 5, 1, 180)

        lastMode := IniReadString(f, "App", "LastMode", "Pomodoro")
        if (lastMode != "Pomodoro" && lastMode != "Short Break" && lastMode != "Long Break")
            lastMode := "Pomodoro"
        this.Settings["LastMode"] := lastMode
        this.Settings["ActiveTaskId"] := IniReadInt(f, "App", "ActiveTaskId", 0, 0, 2147483647)

        x := IniReadString(f, "Window", "X", "")
        y := IniReadString(f, "Window", "Y", "")
        this.Settings["WinX"] := RegExMatch(x, "^-?\d+$") ? x + 0 : ""
        this.Settings["WinY"] := RegExMatch(y, "^-?\d+$") ? y + 0 : ""
    }

    static SaveSettings()
    {
        s := this.Settings
        text := "; PomodoroApp settings - written atomically`n"
        text .= "[Timer]`n"
        text .= "Pomodoro=" this.IntVal(s, "Pomodoro", 25) "`n"
        text .= "ShortBreak=" this.IntVal(s, "ShortBreak", 5) "`n"
        text .= "LongBreak=" this.IntVal(s, "LongBreak", 15) "`n"
        text .= "LongBreakInterval=" this.IntVal(s, "LongBreakInterval", 4) "`n"
        text .= "[Behavior]`n"
        text .= "AutoStartBreaks=" this.IntVal(s, "AutoStartBreaks", 0) "`n"
        text .= "AutoStartPomodoros=" this.IntVal(s, "AutoStartPomodoros", 0) "`n"
        text .= "AutoSwitchTask=" this.IntVal(s, "AutoSwitchTask", 0) "`n"
        text .= "CloseToTray=" this.IntVal(s, "CloseToTray", 1) "`n"
        text .= "AlwaysOnTop=" this.IntVal(s, "AlwaysOnTop", 0) "`n"
        text .= "DarkWhenRunning=" this.IntVal(s, "DarkWhenRunning", 0) "`n"
        text .= "TimeFormat=" this.Get("TimeFormat", "24h") "`n"
        text .= "[Alarm]`n"
        text .= "Sound=" IniValue(this.Get("AlarmSound", A_WinDir "\Media\Alarm01.wav")) "`n"
        text .= "Volume=" this.IntVal(s, "AlarmVolume", 70) "`n"
        text .= "Repeat=" this.IntVal(s, "AlarmRepeat", 1) "`n"
        text .= "[Tick]`n"
        text .= "Enabled=" this.IntVal(s, "Ticking", 0) "`n"
        text .= "Speed=" this.IntVal(s, "TickSpeed", 1) "`n"
        text .= "Volume=" this.IntVal(s, "TickVolume", 60) "`n"
        text .= "[Reminder]`n"
        text .= "Enabled=" this.IntVal(s, "ReminderEnabled", 0) "`n"
        text .= "Type=" this.Get("ReminderType", "BeforeEnd") "`n"
        text .= "Minutes=" this.IntVal(s, "ReminderMinutes", 5) "`n"
        text .= "[App]`n"
        text .= "LastMode=" this.Get("LastMode", "Pomodoro") "`n"
        text .= "ActiveTaskId=" this.ActiveTaskId "`n"
        text .= "[Window]`n"
        text .= "X=" this.Get("WinX", "") "`n"
        text .= "Y=" this.Get("WinY", "") "`n"
        return AtomicWriteText(this.SettingsFile, text)
    }

    static IntVal(MapObj, Key, Default)
    {
        return MapObj.Has(Key) ? ToInt(MapObj[Key], Default) : Default
    }

    static LoadTasks()
    {
        this.Tasks := []
        this.Projects := []
        this.Templates := []
        this.NextTaskId := 1
        this.NextTemplateId := 1
        f := this.TasksFile
        if !FileExist(f)
        {
            this.SaveTasks()
            return
        }

        try
        {
            text := FileRead(f, "UTF-8")
        }
        catch
        {
            this.BackupCorrupt(f)
            this.SaveTasks()
            return
        }

        section := ""
        seenTaskIds := Map()
        seenTemplateIds := Map()
        try
        {
            for rawLine in StrSplit(text, "`n", "`r")
            {
                line := rawLine
                if (line = "" || SubStr(line, 1, 1) = "#")
                    continue
                if (StrLen(line) >= 3 && SubStr(line, 1, 1) = "[" && SubStr(line, StrLen(line), 1) = "]")
                {
                    section := SubStr(line, 2, StrLen(line) - 2)
                    continue
                }
                if (section = "PROJECTS")
                {
                    name := Trim(UnescapeField(line))
                    if (name != "" && !this.HasProject(name))
                        this.Projects.Push(name)
                    continue
                }
                if (section = "TASKS")
                {
                    p := StrSplit(line, "`t")
                    if (p.Length < 8)
                        continue
                    id := ToInt(p[1], 0)
                    if (id <= 0 || seenTaskIds.Has(id))
                        continue
                    name := Trim(UnescapeField(p[2]))
                    if (name = "")
                        continue
                    task := Map(
                        "id", id,
                        "name", name,
                        "estimate", ClampInt(UnescapeField(p[3]), 1, 99, 1),
                        "completed", ClampInt(UnescapeField(p[4]), 0, 99999, 0),
                        "done", ClampInt(UnescapeField(p[5]), 0, 1, 0),
                        "project", Trim(UnescapeField(p[6])),
                        "note", UnescapeField(p[7]),
                        "created", UnescapeField(p[8])
                    )
                    this.Tasks.Push(task)
                    seenTaskIds[id] := true
                    this.NextTaskId := Max(this.NextTaskId, id + 1)
                    if (task["project"] != "" && !this.HasProject(task["project"]))
                        this.Projects.Push(task["project"])
                    continue
                }
                if (section = "TEMPLATES")
                {
                    p := StrSplit(line, "`t")
                    if (p.Length < 5)
                        continue
                    id := ToInt(p[1], 0)
                    if (id <= 0 || seenTemplateIds.Has(id))
                        continue
                    name := Trim(UnescapeField(p[2]))
                    if (name = "")
                        continue
                    this.Templates.Push(Map(
                        "id", id,
                        "name", name,
                        "estimate", ClampInt(UnescapeField(p[3]), 1, 99, 1),
                        "project", Trim(UnescapeField(p[4])),
                        "note", UnescapeField(p[5])
                    ))
                    seenTemplateIds[id] := true
                    this.NextTemplateId := Max(this.NextTemplateId, id + 1)
                }
            }
        }
        catch
        {
            this.Tasks := []
            this.Projects := []
            this.Templates := []
            this.NextTaskId := 1
            this.NextTemplateId := 1
            this.BackupCorrupt(f)
            this.SaveTasks()
        }
    }

    static SaveTasks()
    {
        text := "; PomodoroApp tasks and templates (tab-separated; escaped fields)`n"
        text .= "[PROJECTS]`n"
        for project in this.Projects
            text .= EscapeField(project) "`n"
        text .= "[TASKS]`n"
        for t in this.Tasks
        {
            text .= t["id"] "`t"
                . EscapeField(t["name"]) "`t"
                . t["estimate"] "`t"
                . t["completed"] "`t"
                . t["done"] "`t"
                . EscapeField(t["project"]) "`t"
                . EscapeField(t["note"]) "`t"
                . EscapeField(t["created"]) "`n"
        }
        text .= "[TEMPLATES]`n"
        for t in this.Templates
        {
            text .= t["id"] "`t"
                . EscapeField(t["name"]) "`t"
                . t["estimate"] "`t"
                . EscapeField(t["project"]) "`t"
                . EscapeField(t["note"]) "`n"
        }
        return AtomicWriteText(this.TasksFile, text)
    }

    static LoadHistory()
    {
        this.History := []
        f := this.HistoryFile
        if !FileExist(f)
        {
            this.SaveHistory()
            return
        }
        try
        {
            text := FileRead(f, "UTF-8")
            records := ParseCsv(text)
            first := true
            for row in records
            {
                if first
                {
                    first := false
                    if (row.Length > 0 && StrLower(Trim(row[1])) = "date")
                        continue
                }
                if (row.Length < 5)
                    continue
                date := Trim(row[1])
                if !RegExMatch(date, "^\d{4}-\d{2}-\d{2}$")
                    continue
                minutes := ToInt(row[3], 0)
                if (minutes <= 0)
                    continue
                this.History.Push(Map(
                    "date", date,
                    "start", Trim(row[2]),
                    "minutes", minutes,
                    "task", row[4],
                    "project", row[5]
                ))
            }
        }
        catch
        {
            this.History := []
            this.BackupCorrupt(f)
            this.SaveHistory()
        }
    }

    static SaveHistory()
    {
        text := "Date,StartTime,Minutes,Task,Project`r`n"
        for r in this.History
        {
            text .= CsvField(r["date"]) ","
                . CsvField(r["start"]) ","
                . CsvField(r["minutes"]) ","
                . CsvField(r["task"]) ","
                . CsvField(r["project"]) "`r`n"
        }
        return AtomicWriteText(this.HistoryFile, text)
    }

    static AddHistory(Date, StartTime, Minutes, TaskName, ProjectName)
    {
        this.History.Push(Map(
            "date", Date,
            "start", StartTime,
            "minutes", Minutes,
            "task", TaskName,
            "project", ProjectName
        ))
        this.SaveHistory()
    }

    static BackupCorrupt(File)
    {
        try
        {
            if FileExist(File)
                FileMove(File, File "." FormatTime(A_Now, "yyyyMMddHHmmss") ".corrupt", true)
        }
    }

    static ValidateActiveTask()
    {
        this.ActiveTaskId := ToInt(this.Settings["ActiveTaskId"], 0)
        t := this.TaskById(this.ActiveTaskId)
        if (!t || t["done"])
            this.ActiveTaskId := 0
        this.Settings["ActiveTaskId"] := this.ActiveTaskId
    }

    static TaskById(Id)
    {
        for t in this.Tasks
        {
            if (t["id"] = Id)
                return t
        }
        return 0
    }

    static TaskIndexById(Id)
    {
        for idx, t in this.Tasks
        {
            if (t["id"] = Id)
                return idx
        }
        return 0
    }

    static TemplateById(Id)
    {
        for t in this.Templates
        {
            if (t["id"] = Id)
                return t
        }
        return 0
    }

    static HasProject(Name)
    {
        wanted := StrLower(Trim(Name))
        for p in this.Projects
        {
            if (StrLower(p) = wanted)
                return true
        }
        return false
    }

    static ProjectNames(IncludeHistory := true)
    {
        items := []
        for p in this.Projects
            items.Push(p)
        for t in this.Tasks
        {
            if (t["project"] != "")
                items.Push(t["project"])
        }
        if IncludeHistory
        {
            for r in this.History
            {
                if (r["project"] != "")
                    items.Push(r["project"])
            }
        }
        return SortUniqueStrings(items)
    }

    static ActiveTask()
    {
        return this.TaskById(this.ActiveTaskId)
    }

    static CaptureWindowPos()
    {
        if !MainUI.Gui
            return
        try
        {
            hwnd := MainUI.Gui.Hwnd
            if !WinExist("ahk_id " hwnd)
                return
            if (WinGetMinMax("ahk_id " hwnd) != 0)
                return
            WinGetPos(&x, &y, , , "ahk_id " hwnd)
            if (x < -30000 || y < -30000)
                return
            ; WinGetPos/WinMove use physical screen coordinates, which are
            ; unambiguous across DPI settings.
            this.Settings["WinX"] := x
            this.Settings["WinY"] := y
        }
        catch
        {
            return
        }
    }
}

; ============================================================================
; Sound handling: WAV volume scaling without external libraries
; ============================================================================

class SoundScaler
{
    static Cache := Map()
    static CacheDir := ""
    static TickSource := ""
    static LastError := ""

    static Init(BaseDir)
    {
        this.CacheDir := BaseDir "\cache"
        try DirCreate(this.CacheDir)
        ; Clear previous scaled copies so the cache cannot grow forever.
        try
        {
            Loop Files, this.CacheDir "\*.wav"
                FileDelete(A_LoopFilePath)
        }
        this.Cache := Map()

        this.TickSource := A_WinDir "\Media\Windows Menu Command.wav"
        if !FileExist(this.TickSource)
            this.TickSource := A_WinDir "\Media\Windows Navigation Start.wav"
        if !FileExist(this.TickSource)
            this.TickSource := A_WinDir "\Media\ding.wav"
    }

    static Prepare(Path, Volume)
    {
        Volume := ClampInt(Volume, 0, 100, 100)
        if (Volume <= 0)
            return ""
        if (Volume >= 100)
        {
            ; SoundPlay has a 127-character path quirk; stage unusually long
            ; custom paths through the short cache directory.
            if (StrLen(Path) <= 120)
                return Path
            try
            {
                out := this.CacheDir "\plain_" A_TickCount "_" Random(1000, 9999) ".wav"
                FileCopy(Path, out, 1)
                if FileExist(out)
                    return out
            }
            return Path
        }
        if !FileExist(Path)
            return Path

        try
        {
            key := Path "|" Volume "|" FileGetSize(Path) "|" FileGetTime(Path, "M")
        }
        catch
            return Path

        if (this.Cache.Has(key) && FileExist(this.Cache[key]))
            return this.Cache[key]

        built := this.Build(Path, Volume)
        if (built != "")
        {
            this.Cache[key] := built
            return built
        }
        return Path
    }

    static Build(Path, Volume)
    {
        ; Supports uncompressed PCM WAV (8/16/24/32-bit) and 32/64-bit float.
        ; Non-PCM files are played unchanged, which is a safe fallback.
        try
        {
            if (FileGetSize(Path) < 44 || FileGetSize(Path) > 25 * 1024 * 1024)
            {
                this.LastError := "size"
                return ""
            }
            buf := FileRead(Path, "RAW")
            if (buf.Size < 44)
            {
                this.LastError := "small buffer"
                return ""
            }
            if (NumGet(buf, 0, "UInt") != 0x46464952 || NumGet(buf, 8, "UInt") != 0x45564157)
            {
                this.LastError := "not RIFF/WAVE"
                return ""
            }

            pos := 12
            audioFormat := 0
            bits := 0
            dataOff := 0
            dataLen := 0
            while (pos + 8 <= buf.Size)
            {
                id := NumGet(buf, pos, "UInt")
                len := NumGet(buf, pos + 4, "UInt")
                off := pos + 8
                if (off + len > buf.Size)
                    break
                if (id = 0x20746D66 && len >= 16) ; "fmt "
                {
                    audioFormat := NumGet(buf, off, "UShort")
                    bits := NumGet(buf, off + 14, "UShort")
                }
                else if (id = 0x61746164) ; "data"
                {
                    dataOff := off
                    dataLen := len
                }
                pos := off + len + Mod(len, 2)
            }

            supported := false
            if (audioFormat = 1 && (bits = 8 || bits = 16 || bits = 24 || bits = 32))
                supported := true
            if (audioFormat = 3 && (bits = 32 || bits = 64))
                supported := true
            if (!supported || dataOff = 0 || dataLen = 0)
            {
                this.LastError := "unsupported format " audioFormat "/" bits
                return ""
            }

            factor := Volume / 100.0
            end := dataOff + dataLen
            if (audioFormat = 1)
            {
                if (bits = 8)
                {
                    i := dataOff
                    while (i < end)
                    {
                        v := NumGet(buf, i, "UChar") - 128
                        v := Round(v * factor)
                        if (v > 127)
                            v := 127
                        if (v < -128)
                            v := -128
                        NumPut("UChar", v + 128, buf, i)
                        i += 1
                    }
                }
                else if (bits = 16)
                {
                    i := dataOff
                    while (i + 1 < end)
                    {
                        v := NumGet(buf, i, "Short")
                        v := Round(v * factor)
                        if (v > 32767)
                            v := 32767
                        if (v < -32768)
                            v := -32768
                        NumPut("Short", v, buf, i)
                        i += 2
                    }
                }
                else if (bits = 24)
                {
                    i := dataOff
                    while (i + 2 < end)
                    {
                        v := NumGet(buf, i, "UChar")
                            | (NumGet(buf, i + 1, "UChar") << 8)
                            | (NumGet(buf, i + 2, "UChar") << 16)
                        if (v & 0x800000)
                            v -= 0x1000000
                        v := Round(v * factor)
                        if (v > 8388607)
                            v := 8388607
                        if (v < -8388608)
                            v := -8388608
                        NumPut("UChar", v & 0xFF, buf, i)
                        NumPut("UChar", (v >> 8) & 0xFF, buf, i + 1)
                        NumPut("UChar", (v >> 16) & 0xFF, buf, i + 2)
                        i += 3
                    }
                }
                else
                {
                    i := dataOff
                    while (i + 3 < end)
                    {
                        v := NumGet(buf, i, "Int")
                        v := Round(v * factor)
                        if (v > 2147483647)
                            v := 2147483647
                        if (v < -2147483648)
                            v := -2147483648
                        NumPut("Int", v, buf, i)
                        i += 4
                    }
                }
            }
            else if (bits = 32)
            {
                i := dataOff
                while (i + 3 < end)
                {
                    v := NumGet(buf, i, "Float") * factor
                    if (v > 1.0)
                        v := 1.0
                    if (v < -1.0)
                        v := -1.0
                    NumPut("Float", v, buf, i)
                    i += 4
                }
            }
            else
            {
                i := dataOff
                while (i + 7 < end)
                {
                    v := NumGet(buf, i, "Double") * factor
                    if (v > 1.0)
                        v := 1.0
                    if (v < -1.0)
                        v := -1.0
                    NumPut("Double", v, buf, i)
                    i += 8
                }
            }

            out := this.CacheDir "\scaled_" A_TickCount "_" Random(1000, 9999) ".wav"
            f := FileOpen(out, "w")
            f.RawWrite(buf, buf.Size)
            f.Close()
            if !FileExist(out)
            {
                this.LastError := "output missing"
                return ""
            }
            this.LastError := ""
            return out
        }
        catch as e
        {
            this.LastError := e.Message " @ " e.Line
            return ""
        }
    }
}

class AlarmPlayer
{
    static RepeatLeft := 0
    static SoundPath := ""

    static Play(TestOnly := false)
    {
        src := Store.Get("AlarmSound", A_WinDir "\Media\Alarm01.wav")
        if !FileExist(src)
            src := A_WinDir "\Media\Alarm01.wav"
        if !FileExist(src)
            return
        vol := Store.Get("AlarmVolume", 70)
        if (vol <= 0)
            return
        this.SoundPath := SoundScaler.Prepare(src, vol)
        if (this.SoundPath = "")
            return
        this.RepeatLeft := TestOnly ? 1 : ClampInt(Store.Get("AlarmRepeat", 1), 1, 5, 1)
        this.PlayNext()
    }

    static PlayNext()
    {
        if (this.RepeatLeft <= 0)
            return
        try SoundPlay(this.SoundPath)
        this.RepeatLeft -= 1
        if (this.RepeatLeft > 0)
            SetTimer(AlarmNext, -2300)
    }
}

AlarmNext(*)
{
    AlarmPlayer.PlayNext()
}

class TickPlayer
{
    static Play()
    {
        if (SoundScaler.TickSource = "" || !FileExist(SoundScaler.TickSource))
            return
        vol := Store.Get("TickVolume", 60)
        if (vol <= 0)
            return
        path := SoundScaler.Prepare(SoundScaler.TickSource, vol)
        if (path = "")
            return
        try SoundPlay(path)
    }
}

; ============================================================================
; Timer engine
; ============================================================================

class TimerEngine
{
    static Mode := "Pomodoro"
    static Running := false
    static RemainingMs := 0
    static EndTick := 0
    static SessionNum := 1
    static CycleCount := 0
    static PhaseStart := ""
    static PhaseTotalMs := 0
    static ReminderFired := false
    static TickDivider := 0
    static SyncTick := 0
    static SyncUtc := ""

    static Init()
    {
        mode := Store.Get("LastMode", "Pomodoro")
        if (mode != "Pomodoro" && mode != "Short Break" && mode != "Long Break")
            mode := "Pomodoro"
        this.Mode := mode
        this.Running := false
        this.RemainingMs := this.DurationFor(mode)
        this.PhaseTotalMs := this.RemainingMs
        this.EndTick := 0
        this.SessionNum := 1
        this.CycleCount := 0
        this.PhaseStart := ""
        this.ReminderFired := false
        this.TickDivider := 0
    }

    static DurationFor(ModeName)
    {
        minutes := 25
        if (ModeName = "Short Break")
            minutes := Store.Get("ShortBreak", 5)
        else if (ModeName = "Long Break")
            minutes := Store.Get("LongBreak", 15)
        else
            minutes := Store.Get("Pomodoro", 25)
        return Max(1, ToInt(minutes, 25)) * 60000
    }

    static Remaining()
    {
        if !this.Running
            return Max(0, this.RemainingMs)
        rem := this.EndTick - A_TickCount
        if (rem < 0 && (A_TickCount - this.EndTick) > 0x7FFFFFFF)
            rem += 0x100000000
        return Max(0, rem)
    }

    static TimeString()
    {
        rem := this.Remaining()
        secs := (rem + 999) // 1000
        return Format("{:02}:{:02}", secs // 60, Mod(secs, 60))
    }

    static SessionText()
    {
        if (this.Mode = "Pomodoro")
            return "#" this.SessionNum " Time to focus!"
        return "Time for a break!"
    }

    static TitleText()
    {
        phase := (this.Mode = "Pomodoro")
            ? ("#" this.SessionNum " Time to focus!")
            : "Time for a break!"
        return this.TimeString() " - " this.Mode " - " phase
    }

    static HasProgress()
    {
        return (this.PhaseStart != "" && this.RemainingMs < this.PhaseTotalMs && this.RemainingMs > 0)
    }

    static Start()
    {
        if this.Running
            return
        if (this.RemainingMs <= 0)
        {
            this.RemainingMs := this.DurationFor(this.Mode)
            this.PhaseTotalMs := this.RemainingMs
        }
        if (this.PhaseStart = "")
        {
            this.PhaseStart := A_Now
            this.PhaseTotalMs := this.RemainingMs
            this.ReminderFired := false
        }
        this.EndTick := A_TickCount + this.RemainingMs
        this.Running := true
        this.TickDivider := 0
        this.SyncTick := A_TickCount
        this.SyncUtc := A_NowUTC
        SetTimer(TimerTickHandler, 1000)
        MainUI.UpdateAll()
    }

    static Pause()
    {
        if !this.Running
            return
        this.RemainingMs := this.Remaining()
        this.EndTick := 0
        this.Running := false
        this.SyncTick := 0
        this.SyncUtc := ""
        SetTimer(TimerTickHandler, 0)
        MainUI.UpdateAll()
    }

    static Toggle()
    {
        if this.Running
            this.Pause()
        else
            this.Start()
    }

    static SwitchTo(ModeName)
    {
        if (ModeName != "Pomodoro" && ModeName != "Short Break" && ModeName != "Long Break")
            return
        if (this.Mode = ModeName && !this.Running && this.PhaseStart = "" && this.RemainingMs = this.DurationFor(ModeName))
            return
        SetTimer(TimerTickHandler, 0)
        this.Running := false
        this.EndTick := 0
        this.PrepareMode(ModeName)
        MainUI.UpdateAll()
    }

    static PrepareMode(ModeName)
    {
        this.Mode := ModeName
        this.RemainingMs := this.DurationFor(ModeName)
        this.PhaseTotalMs := this.RemainingMs
        this.EndTick := 0
        this.PhaseStart := ""
        this.ReminderFired := false
        this.TickDivider := 0
        this.SyncTick := 0
        this.SyncUtc := ""
        Store.Set("LastMode", ModeName)
        Store.SaveSettings()
    }

    static OnTick()
    {
        if !this.Running
            return
        this.AccountForSleep()
        rem := this.Remaining()
        if (rem <= 0)
        {
            this.CompletePhase()
            return
        }

        this.CheckReminder(rem)
        this.TickDivider += 1
        if Store.Get("Ticking", 0)
        {
            speed := ClampInt(Store.Get("TickSpeed", 1), 1, 3, 1)
            if (Mod(this.TickDivider, speed) = 0)
                TickPlayer.Play()
        }
        MainUI.UpdateTimerDisplay()
        MainUI.UpdateFinish()
    }

    static AccountForSleep()
    {
        ; A_TickCount handles lag without drift. This extra wall-clock check
        ; also catches long sleep/suspend gaps on systems where tick time pauses.
        nowTick := A_TickCount
        nowUtc := A_NowUTC
        if (this.SyncTick = 0)
        {
            this.SyncTick := nowTick
            this.SyncUtc := nowUtc
            return
        }
        tickSeconds := (nowTick - this.SyncTick) / 1000.0
        wallSeconds := DateDiff(nowUtc, this.SyncUtc, "Seconds")
        this.SyncTick := nowTick
        this.SyncUtc := nowUtc
        if (wallSeconds > tickSeconds + 2 && wallSeconds < 86400)
        {
            extraMs := Round((wallSeconds - tickSeconds) * 1000)
            this.EndTick -= extraMs
        }
    }

    static CheckReminder(Remaining)
    {
        if this.ReminderFired || !Store.Get("ReminderEnabled", 0)
            return
        minutes := ClampInt(Store.Get("ReminderMinutes", 5), 1, 180, 5)
        threshold := minutes * 60000
        typ := Store.Get("ReminderType", "BeforeEnd")
        if (typ = "AfterStart")
        {
            elapsed := this.PhaseTotalMs - Remaining
            if (elapsed >= threshold)
            {
                this.ReminderFired := true
                TrayTip(minutes " minutes into this session.", "Pomodoro reminder", "Iconi")
            }
        }
        else if (Remaining <= threshold)
        {
            this.ReminderFired := true
            left := Max(1, (Remaining + 59999) // 60000)
            TrayTip(left " minute" (left = 1 ? "" : "s") " left in this session.", "Pomodoro reminder", "Iconi")
        }
    }

    static CompletePhase()
    {
        if !this.Running
            return
        completedMode := this.Mode
        this.Running := false
        this.RemainingMs := 0
        this.EndTick := 0
        SetTimer(TimerTickHandler, 0)

        nextMode := "Pomodoro"
        autoStart := false
        if (completedMode = "Pomodoro")
        {
            this.RecordFocusSession()
            this.SessionNum += 1
            this.CycleCount += 1
            interval := ClampInt(Store.Get("LongBreakInterval", 4), 1, 12, 4)
            if (this.CycleCount >= interval)
            {
                nextMode := "Long Break"
                this.CycleCount := 0
            }
            else
            {
                nextMode := "Short Break"
            }
            autoStart := Store.Get("AutoStartBreaks", 0) ? true : false
        }
        else
        {
            nextMode := "Pomodoro"
            autoStart := Store.Get("AutoStartPomodoros", 0) ? true : false
        }

        this.PrepareMode(nextMode)
        MainUI.UpdateAll()
        this.NotifyCompletion(completedMode, nextMode)
        if autoStart
            this.Start()
    }

    static RecordFocusSession()
    {
        active := Store.ActiveTask()
        taskName := active ? active["name"] : ""
        project := active ? active["project"] : ""
        startTime := FormatTime(this.PhaseStart != "" ? this.PhaseStart : A_Now, "HH:mm")
        date := FormatTime(this.PhaseStart != "" ? this.PhaseStart : A_Now, "yyyy-MM-dd")
        minutes := Max(1, Round(this.PhaseTotalMs / 60000))
        Store.AddHistory(date, startTime, minutes, taskName, project)
        if (active && !active["done"])
        {
            active["completed"] += 1
            Store.SaveTasks()
        }
        MainUI.RefreshTasks()
        MainUI.UpdateFinish()
    }

    static NotifyCompletion(CompletedMode, NextMode)
    {
        message := ""
        if (CompletedMode = "Pomodoro")
        {
            if (NextMode = "Long Break")
                message := "Pomodoro complete. Time for a long break!"
            else
                message := "Pomodoro complete. Time for a short break!"
        }
        else
        {
            message := "Break complete. Time to focus!"
        }

        TrayTip(message, "Pomodoro", "Iconi")
        AlarmPlayer.Play()
        MainUI.Reveal()
        try MainUI.Gui.Flash()
        SetTimer(ClearFlash, -2500)
    }

    static SkipPhase()
    {
        completed := this.Mode
        SetTimer(TimerTickHandler, 0)
        this.Running := false
        this.RemainingMs := 0
        this.EndTick := 0

        nextMode := "Pomodoro"
        if (completed = "Pomodoro")
            nextMode := "Short Break"
        else
            nextMode := "Pomodoro"

        this.PrepareMode(nextMode)
        MainUI.UpdateAll()

        autoStart := (nextMode = "Pomodoro")
            ? (Store.Get("AutoStartPomodoros", 0) ? true : false)
            : (Store.Get("AutoStartBreaks", 0) ? true : false)
        if autoStart
            this.Start()
    }

    static OnSettingsChanged()
    {
        ; Only reset an unstarted phase. A paused session keeps its progress.
        if (!this.Running && this.PhaseStart = "")
        {
            this.RemainingMs := this.DurationFor(this.Mode)
            this.PhaseTotalMs := this.RemainingMs
        }
        MainUI.UpdateAll()
    }
}

TimerTickHandler(*)
{
    TimerEngine.OnTick()
}

ClearFlash(*)
{
    try
    {
        if MainUI.Gui
            MainUI.Gui.Flash(false)
    }
}

; ============================================================================
; Main window
; ============================================================================

class MainUI
{
    static Gui := 0
    static ModeButtons := Map()
    static SessionText := 0
    static ActiveText := 0
    static TimerText := 0
    static StartBtn := 0
    static SkipBtn := 0
    static FinishText := 0
    static TaskLV := 0
    static RowIds := []
    static ContextTaskId := 0
    static LastRunning := -1
    static LastProgress := -1
    static LastMode := ""
    static Colors := Map("Pomodoro", "BA4949", "Short Break", "38858A", "Long Break", "397097")
    static DarkColors := Map("Pomodoro", "7A2F2F", "Short Break", "245A5D", "Long Break", "244A63")

    static Build()
    {
        g := Gui("+MinimizeBox", "Pomodoro")
        this.Gui := g
        g.BackColor := "BA4949"
        g.SetFont("s10", "Segoe UI")

        this.ModeButtons["Pomodoro"] := g.Add("Button", "x20 y14 w180 h34", "Pomodoro")
        this.ModeButtons["Short Break"] := g.Add("Button", "x200 y14 w180 h34", "Short Break")
        this.ModeButtons["Long Break"] := g.Add("Button", "x380 y14 w180 h34", "Long Break")
        for name, btn in this.ModeButtons
        {
            btn.OnEvent("Click", ModeButtonClicked.Bind(name))
        }

        g.SetFont("s13 bold", "Segoe UI")
        this.SessionText := g.Add("Text", "x20 y58 w540 h28 Center cWhite BackgroundTrans -Wrap", "#1 Time to focus!")

        g.SetFont("s10", "Segoe UI")
        this.ActiveText := g.Add("Text", "x20 y91 w540 h24 Center cWhite BackgroundTrans -Wrap", "Working on: (no task selected)")

        g.SetFont("s62 bold", "Segoe UI")
        this.TimerText := g.Add("Text", "x20 y114 w540 h92 Center cWhite BackgroundTrans -Wrap", "25:00")

        g.SetFont("s16 bold", "Segoe UI")
        this.StartBtn := g.Add("Button", "x165 y216 w250 h50", "Start")
        this.StartBtn.OnEvent("Click", StartButtonClicked)
        this.SkipBtn := g.Add("Button", "x355 y216 w130 h50 Hidden", "Skip")
        this.SkipBtn.OnEvent("Click", SkipButtonClicked)

        g.SetFont("s10", "Segoe UI")
        this.FinishText := g.Add("Text", "x20 y276 w540 h24 Center cWhite BackgroundTrans -Wrap", "Pomos: 0/0  No tasks yet")

        g.SetFont("s11 bold", "Segoe UI")
        g.Add("Text", "x20 y305 w120 h26 cWhite BackgroundTrans", "Tasks")
        g.SetFont("s10", "Segoe UI")
        addTaskBtn := g.Add("Button", "x460 y300 w100 h30", "Add Task")
        addTaskBtn.OnEvent("Click", AddTaskClicked)

        this.TaskLV := g.Add("ListView", "x20 y338 w540 h190 Checked Grid -Multi NoSort NoSortHdr", ["Task", "Pomos", "Project", "Active"])
        this.TaskLV.SetFont("s9 c000000", "Segoe UI")
        this.TaskLV.ModifyCol(1, 235)
        this.TaskLV.ModifyCol(2, "80 Integer")
        this.TaskLV.ModifyCol(3, 140)
        this.TaskLV.ModifyCol(4, "50 Center")
        this.TaskLV.OnEvent("Click", TaskListClicked)
        this.TaskLV.OnEvent("DoubleClick", TaskListDoubleClicked)
        this.TaskLV.OnEvent("ItemCheck", TaskListItemChecked)
        this.TaskLV.OnEvent("ContextMenu", TaskListContextMenu)

        editBtn := g.Add("Button", "x20 y536 w70 h30", "Edit")
        editBtn.OnEvent("Click", EditTaskClicked)
        deleteBtn := g.Add("Button", "x96 y536 w70 h30", "Delete")
        deleteBtn.OnEvent("Click", DeleteTaskClicked)
        taskMenuBtn := g.Add("Button", "x172 y536 w100 h30", "Task menu")
        taskMenuBtn.OnEvent("Click", TaskMenuClicked)
        templatesBtn := g.Add("Button", "x278 y536 w100 h30", "Templates")
        templatesBtn.OnEvent("Click", TemplatesClicked)
        projectsBtn := g.Add("Button", "x384 y536 w100 h30", "Projects")
        projectsBtn.OnEvent("Click", ProjectsClicked)

        settingsBtn := g.Add("Button", "x20 y578 w120 h34", "Settings")
        settingsBtn.OnEvent("Click", SettingsClicked)
        reportsBtn := g.Add("Button", "x150 y578 w120 h34", "Reports")
        reportsBtn.OnEvent("Click", ReportsClicked)
        g.SetFont("s9", "Segoe UI")
        g.Add("Text", "x282 y584 w278 h22 cWhite BackgroundTrans -Wrap", "Use the tray menu to exit.")

        g.OnEvent("Close", MainWindowClose)
        g.OnEvent("Escape", MainWindowEscape)
    }

    static ShowInitial()
    {
        width := 580
        height := 640
        this.Gui.Show("w" width " h" height " Center")

        x := Store.Get("WinX", "")
        y := Store.Get("WinY", "")
        if (x = "" || y = "")
            return

        ; Restore in physical coordinates, then keep the window reachable.
        try
        {
            hwnd := this.Gui.Hwnd
            WinGetPos(&wx, &wy, &w, &h, "ahk_id " hwnd)
            ClampWindowToScreen(&x, &y, w, h)
            WinMove(x, y, , , "ahk_id " hwnd)
        }
        this.UpdateAll()
    }

    static Reveal()
    {
        if !this.Gui
            return
        try
        {
            this.Gui.Show("NoActivate")
            if (WinGetMinMax("ahk_id " this.Gui.Hwnd) = -1)
                this.Gui.Restore()
            WinActivate("ahk_id " this.Gui.Hwnd)
        }
    }

    static UpdateAll()
    {
        this.UpdateTheme()
        this.UpdateTimerDisplay()
        this.UpdateActiveTask()
        this.RefreshTasks()
        this.UpdateFinish()
    }

    static UpdateTheme()
    {
        if !this.Gui
            return
        mode := TimerEngine.Mode
        dark := Store.Get("DarkWhenRunning", 0) && TimerEngine.Running
        if dark && this.DarkColors.Has(mode)
            this.Gui.BackColor := this.DarkColors[mode]
        else
            this.Gui.BackColor := this.Colors.Has(mode) ? this.Colors[mode] : "BA4949"
    }

    static UpdateTimerDisplay()
    {
        if !this.Gui
            return
        this.TimerText.Value := TimerEngine.TimeString()
        this.SessionText.Value := TimerEngine.SessionText()

        running := TimerEngine.Running
        progress := TimerEngine.HasProgress()
        if (running != this.LastRunning)
        {
            this.LastRunning := running
            this.SkipBtn.Visible := running
            if running
            {
                this.StartBtn.Move(95, 216, 250, 50)
                this.SkipBtn.Move(355, 216, 130, 50)
                this.StartBtn.Text := "Pause"
            }
            else
            {
                this.StartBtn.Move(165, 216, 250, 50)
                this.StartBtn.Text := progress ? "Resume" : "Start"
            }
        }
        else if (!running && progress != this.LastProgress)
        {
            this.StartBtn.Text := progress ? "Resume" : "Start"
        }
        this.LastProgress := progress

        if (this.LastMode != TimerEngine.Mode)
        {
            for name, btn in this.ModeButtons
            {
                active := (name = TimerEngine.Mode)
                btn.Text := active ? ("> " name " <") : name
                btn.SetFont(active ? "s10 bold" : "s10", "Segoe UI")
            }
            this.LastMode := TimerEngine.Mode
        }

        title := TimerEngine.TitleText()
        this.Gui.Title := title
        if (A_IconTip != title)
            A_IconTip := title
    }

    static UpdateActiveTask()
    {
        if !this.ActiveText
            return
        t := Store.ActiveTask()
        this.ActiveText.Value := t ? ("Working on: " t["name"]) : "Working on: (no task selected)"
    }

    static UpdateFinish()
    {
        if !this.FinishText
            return
        totalEst := 0
        totalDone := 0
        remainingSessions := 0
        for t in Store.Tasks
        {
            totalEst += t["estimate"]
            totalDone += t["completed"]
            if !t["done"]
                remainingSessions += Max(0, t["estimate"] - t["completed"])
        }

        progress := "Pomos: " totalDone "/" totalEst
        if (Store.Tasks.Length = 0)
        {
            this.FinishText.Value := progress "  No tasks yet"
            return
        }
        if (remainingSessions <= 0)
        {
            this.FinishText.Value := progress "  All tasks complete"
            return
        }

        pomo := Max(1, ToInt(Store.Get("Pomodoro", 25), 25))
        short := Max(1, ToInt(Store.Get("ShortBreak", 5), 5))
        long := Max(1, ToInt(Store.Get("LongBreak", 15), 15))
        interval := ClampInt(Store.Get("LongBreakInterval", 4), 1, 12, 4)

        breakMinutes := 0
        cycle := TimerEngine.CycleCount
        Loop remainingSessions - 1
        {
            cycle += 1
            if (Mod(cycle, interval) = 0)
                breakMinutes += long
            else
                breakMinutes += short
        }
        totalMinutes := remainingSessions * pomo + breakMinutes
        finishAt := DateAdd(A_Now, totalMinutes, "Minutes")
        fmt := (Store.Get("TimeFormat", "24h") = "12h") ? "h:mm tt" : "HH:mm"
        this.FinishText.Value := progress "  Finish at " FormatTime(finishAt, fmt)
            . " (" FormatDuration(totalMinutes) ")"
    }

    static RefreshTasks()
    {
        if !this.TaskLV
            return
        this.TaskLV.Opt("-Redraw")
        this.TaskLV.Delete()
        this.RowIds := []
        for t in Store.Tasks
        {
            opts := t["done"] ? "Check" : ""
            row := this.TaskLV.Add(opts, t["name"], t["completed"] "/" t["estimate"], t["project"] = "" ? "-" : t["project"], t["id"] = Store.ActiveTaskId ? "*" : "")
            this.RowIds.Push(t["id"])
            if (t["id"] = Store.ActiveTaskId)
                this.TaskLV.Modify(row, "Select Vis")
        }
        this.TaskLV.Opt("+Redraw")
        this.UpdateActiveTask()
        this.UpdateFinish()
    }

    static RowTaskId(Row)
    {
        if (Row < 1 || Row > this.RowIds.Length)
            return 0
        return this.RowIds[Row]
    }

    static SelectedTaskId()
    {
        if !this.TaskLV
            return 0
        row := this.TaskLV.GetNext(0, "Focused")
        if !row
            row := this.TaskLV.GetNext(0, "Selected")
        return row ? this.RowTaskId(row) : 0
    }

    static SavePosition()
    {
        Store.CaptureWindowPos()
        Store.SaveSettings()
    }
}

; ============================================================================
; Main-window event handlers
; ============================================================================

ModeButtonClicked(ModeName, *)
{
    TimerEngine.SwitchTo(ModeName)
}

StartButtonClicked(*)
{
    TimerEngine.Toggle()
}

SkipButtonClicked(*)
{
    TimerEngine.SkipPhase()
}

AddTaskClicked(*)
{
    TaskDialog.Open()
}

EditTaskClicked(*)
{
    id := MainUI.SelectedTaskId()
    if !id
    {
        MsgBox("Select a task first.", "Pomodoro", "Iconi")
        return
    }
    TaskDialog.Open(id)
}

DeleteTaskClicked(*)
{
    id := MainUI.SelectedTaskId()
    if !id
    {
        MsgBox("Select a task first.", "Pomodoro", "Iconi")
        return
    }
    DeleteTaskById(id)
}

TaskListClicked(ctrl, row, *)
{
    id := MainUI.RowTaskId(row)
    if !id
        return
    t := Store.TaskById(id)
    if (!t || t["done"] || Store.ActiveTaskId = id)
        return
    Store.ActiveTaskId := id
    Store.Set("ActiveTaskId", id)
    Store.SaveSettings()
    MainUI.RefreshTasks()
}

TaskListDoubleClicked(ctrl, row, *)
{
    id := MainUI.RowTaskId(row)
    if id
        TaskDialog.Open(id)
}

TaskListItemChecked(ctrl, row, checked, *)
{
    id := MainUI.RowTaskId(row)
    t := Store.TaskById(id)
    if !t
        return
    t["done"] := checked ? 1 : 0
    if (t["done"] && Store.ActiveTaskId = id)
    {
        Store.ActiveTaskId := 0
        if Store.Get("AutoSwitchTask", 0)
        {
            nid := NextUnfinishedTaskId(id)
            if nid
                Store.ActiveTaskId := nid
        }
        Store.Set("ActiveTaskId", Store.ActiveTaskId)
        Store.SaveSettings()
    }
    Store.SaveTasks()
    MainUI.RefreshTasks()
}

TaskListContextMenu(ctrl, item, isRight, x, y, *)
{
    id := MainUI.RowTaskId(item)
    if !id
        return
    t := Store.TaskById(id)
    if !t
        return
    thisId := id
    ctrl.Modify(item, "Select Focus")
    m := Menu()
    m.Add("Set as active", (*) => SetTaskActiveById(thisId))
    m.Add("Edit", (*) => TaskDialog.Open(thisId))
    m.Add("Save as template", (*) => SaveTaskAsTemplateById(thisId))
    m.Add()
    if t["done"]
        m.Add("Mark as not done", (*) => SetTaskDoneById(thisId, false))
    else
        m.Add("Mark as done", (*) => SetTaskDoneById(thisId, true))
    m.Add("Delete", (*) => DeleteTaskById(thisId))
    try m.Show(x, y)
}

TaskMenuClicked(*)
{
    m := Menu()
    m.Add("Clear finished tasks", ClearFinishedTasks)
    m.Add("Clear all tasks", ClearAllTasks)
    m.Add()
    m.Add("Reset all pomodoro counts", ResetAllTaskCounts)
    m.Show()
}

TemplatesClicked(*)
{
    ShowTemplatesMenu()
}

ProjectsClicked(*)
{
    ProjectsDialog.Open()
}

SettingsClicked(*)
{
    SettingsDialog.Open()
}

ReportsClicked(*)
{
    ReportsDialog.Open()
}

MainWindowClose(*)
{
    MainUI.SavePosition()
    if Store.Get("CloseToTray", 1)
        MainUI.Gui.Hide()
    else
        MainUI.Gui.Minimize()
    return true
}

MainWindowEscape(*)
{
    ; Escape is deliberately harmless; use the tray menu to exit.
    return
}

; ============================================================================
; Task helpers (full task UI is defined below)
; ============================================================================

NextUnfinishedTaskId(AfterId)
{
    start := Store.TaskIndexById(AfterId)
    count := Store.Tasks.Length
    if (count = 0)
        return 0
    Loop count
    {
        idx := Mod(start + A_Index, count) + 1
        t := Store.Tasks[idx]
        if !t["done"]
            return t["id"]
    }
    return 0
}

SetTaskActiveById(Id)
{
    t := Store.TaskById(Id)
    if (!t || t["done"])
        return
    Store.ActiveTaskId := Id
    Store.Set("ActiveTaskId", Id)
    Store.SaveSettings()
    MainUI.RefreshTasks()
}

SetTaskDoneById(Id, Done)
{
    t := Store.TaskById(Id)
    if !t
        return
    t["done"] := Done ? 1 : 0
    if (Done && Store.ActiveTaskId = Id)
    {
        Store.ActiveTaskId := 0
        if Store.Get("AutoSwitchTask", 0)
        {
            nid := NextUnfinishedTaskId(Id)
            if nid
                Store.ActiveTaskId := nid
        }
        Store.Set("ActiveTaskId", Store.ActiveTaskId)
        Store.SaveSettings()
    }
    Store.SaveTasks()
    MainUI.RefreshTasks()
}

DeleteTaskById(Id)
{
    idx := Store.TaskIndexById(Id)
    if !idx
        return
    t := Store.Tasks[idx]
    if (MsgBox('Delete task "' t["name"] '"?', "Pomodoro", "YesNo Icon!") != "Yes")
        return
    Store.Tasks.RemoveAt(idx)
    if (Store.ActiveTaskId = Id)
    {
        Store.ActiveTaskId := 0
        Store.Set("ActiveTaskId", 0)
        Store.SaveSettings()
    }
    Store.SaveTasks()
    MainUI.RefreshTasks()
}

ClearFinishedTasks(*)
{
    count := 0
    for t in Store.Tasks
    {
        if t["done"]
            count += 1
    }
    if (count = 0)
    {
        MsgBox("There are no finished tasks to clear.", "Pomodoro", "Iconi")
        return
    }
    if (MsgBox("Clear " count " finished task" (count = 1 ? "" : "s") "?", "Pomodoro", "YesNo Icon!") != "Yes")
        return
    newTasks := []
    for t in Store.Tasks
    {
        if !t["done"]
            newTasks.Push(t)
    }
    Store.Tasks := newTasks
    Store.SaveTasks()
    MainUI.RefreshTasks()
}

ClearAllTasks(*)
{
    if (Store.Tasks.Length = 0)
        return
    if (MsgBox("Clear all tasks? History is kept.", "Pomodoro", "YesNo Icon!") != "Yes")
        return
    Store.Tasks := []
    Store.ActiveTaskId := 0
    Store.Set("ActiveTaskId", 0)
    Store.SaveSettings()
    Store.SaveTasks()
    MainUI.RefreshTasks()
}

ResetAllTaskCounts(*)
{
    if (Store.Tasks.Length = 0)
        return
    if (MsgBox("Reset the pomodoro count on every task?", "Pomodoro", "YesNo Icon!") != "Yes")
        return
    for t in Store.Tasks
        t["completed"] := 0
    Store.SaveTasks()
    MainUI.RefreshTasks()
}

SaveTaskAsTemplateById(Id)
{
    t := Store.TaskById(Id)
    if !t
        return
    tmpl := Map(
        "id", Store.NextTemplateId,
        "name", t["name"],
        "estimate", t["estimate"],
        "project", t["project"],
        "note", t["note"]
    )
    Store.NextTemplateId += 1
    Store.Templates.Push(tmpl)
    Store.SaveTasks()
    TrayTip('Saved "' t["name"] '" as a template.', "Pomodoro", "Iconi")
}

SaveSelectedAsTemplate(*)
{
    id := MainUI.SelectedTaskId()
    if !id
        id := Store.ActiveTaskId
    if !id
    {
        MsgBox("Select a task (or make one active) first.", "Pomodoro", "Iconi")
        return
    }
    SaveTaskAsTemplateById(id)
}

ShowTemplatesMenu()
{
    m := Menu()
    if (Store.Templates.Length = 0)
    {
        m.Add("(No templates yet)", NoopHandler)
        m.Disable("(No templates yet)")
    }
    else
    {
        for tmpl in Store.Templates
        {
            label := "Add: " MenuText(tmpl["name"]) " (" tmpl["estimate"] ")"
            m.Add(label, AddTemplateById.Bind(tmpl["id"]))
        }
    }
    m.Add()
    del := Menu()
    if (Store.Templates.Length = 0)
    {
        del.Add("(None)", NoopHandler)
        del.Disable("(None)")
    }
    else
    {
        for tmpl in Store.Templates
            del.Add(MenuText(tmpl["name"]), DeleteTemplateById.Bind(tmpl["id"]))
    }
    m.Add("Delete a template", del)
    m.Add("Save selected task as template", SaveSelectedAsTemplate)
    m.Show()
}

AddTemplateById(Id, *)
{
    tmpl := Store.TemplateById(Id)
    if !tmpl
        return
    task := Map(
        "id", Store.NextTaskId,
        "name", tmpl["name"],
        "estimate", tmpl["estimate"],
        "completed", 0,
        "done", 0,
        "project", tmpl["project"],
        "note", tmpl["note"],
        "created", A_Now
    )
    Store.NextTaskId += 1
    Store.Tasks.Push(task)
    if (Store.TaskById(task["id"]) && tmpl["project"] != "" && !Store.HasProject(tmpl["project"]))
        Store.Projects.Push(tmpl["project"])
    if (Store.ActiveTaskId = 0)
    {
        Store.ActiveTaskId := task["id"]
        Store.Set("ActiveTaskId", task["id"])
        Store.SaveSettings()
    }
    Store.SaveTasks()
    MainUI.RefreshTasks()
}

DeleteTemplateById(Id, *)
{
    tmpl := Store.TemplateById(Id)
    if !tmpl
        return
    if (MsgBox('Delete template "' tmpl["name"] '"?', "Pomodoro", "YesNo Icon!") != "Yes")
        return
    idx := 0
    for i, item in Store.Templates
    {
        if (item["id"] = Id)
        {
            idx := i
            break
        }
    }
    if idx
        Store.Templates.RemoveAt(idx)
    Store.SaveTasks()
}

NoopHandler(*)
{
}

; ============================================================================
; Add / edit task dialog
; ============================================================================

class TaskDialog
{
    static Gui := 0
    static EditId := 0
    static NameEdit := 0
    static EstimateEdit := 0
    static NoteEdit := 0
    static ProjectDDL := 0

    static Open(EditId := 0)
    {
        if this.Gui
        {
            this.Gui.Show()
            try WinActivate("ahk_id " this.Gui.Hwnd)
            return
        }

        this.EditId := EditId
        task := EditId ? Store.TaskById(EditId) : 0
        if (EditId && !task)
            return

        g := Gui("+Owner" MainUI.Gui.Hwnd, task ? "Edit Task" : "Add Task")
        this.Gui := g
        g.SetFont("s10", "Segoe UI")
        g.MarginX := 18
        g.MarginY := 14

        g.Add("Text", "xm", "Task name")
        this.NameEdit := g.Add("Edit", "xm w450", task ? task["name"] : "")
        g.Add("Text", "xm y+12", "Estimated pomodoros")
        this.EstimateEdit := g.Add("Edit", "xm w75", task ? task["estimate"] : 1)

        g.Add("Text", "xm y+12", "Project (optional)")
        projects := ["(No project)"]
        for p in Store.ProjectNames(false)
            projects.Push(p)
        this.ProjectDDL := g.Add("DropDownList", "xm w250", projects)
        this.ProjectDDL.Value := 1
        if (task && task["project"] != "")
        {
            for i, p in projects
            {
                if (StrLower(p) = StrLower(task["project"]))
                {
                    this.ProjectDDL.Value := i
                    break
                }
            }
        }

        g.Add("Text", "xm y+12", "Note (optional)")
        this.NoteEdit := g.Add("Edit", "xm w450 r4 WantReturn", task ? task["note"] : "")

        save := g.Add("Button", "xm y+16 w95 h32 Default", "Save")
        cancel := g.Add("Button", "x+8 w95 h32", "Cancel")
        save.OnEvent("Click", TaskDialogSave)
        cancel.OnEvent("Click", TaskDialogCancel)
        g.OnEvent("Close", TaskDialogClose)
        g.OnEvent("Escape", TaskDialogCancel)
        g.Show("w500 h410 Center")

        try this.NameEdit.Focus()
    }

    static Save()
    {
        name := Trim(this.NameEdit.Value)
        name := RegExReplace(name, "[\r\n\t]+", " ")
        name := Trim(name)
        if (name = "")
        {
            MsgBox("Please enter a task name.", "Pomodoro", "Icon!")
            return
        }
        if (StrLen(name) > 120)
            name := SubStr(name, 1, 120)

        estimate := ToInt(this.EstimateEdit.Value, 0)
        if (estimate < 1 || estimate > 99)
        {
            MsgBox("Estimated pomodoros must be a whole number from 1 to 99.", "Pomodoro", "Icon!")
            return
        }

        project := this.ProjectDDL.Value > 1 ? this.ProjectDDL.Text : ""
        note := this.NoteEdit.Value

        if this.EditId
        {
            task := Store.TaskById(this.EditId)
            if !task
                return
            task["name"] := name
            task["estimate"] := estimate
            task["project"] := project
            task["note"] := note
        }
        else
        {
            task := Map(
                "id", Store.NextTaskId,
                "name", name,
                "estimate", estimate,
                "completed", 0,
                "done", 0,
                "project", project,
                "note", note,
                "created", A_Now
            )
            Store.NextTaskId += 1
            Store.Tasks.Push(task)
            Store.ActiveTaskId := task["id"]
            Store.Set("ActiveTaskId", task["id"])
        }

        Store.SaveTasks()
        Store.SaveSettings()
        MainUI.RefreshTasks()
        this.Close()
    }

    static Close()
    {
        if this.Gui
        {
            try this.Gui.Destroy()
        }
        this.Gui := 0
        this.EditId := 0
        this.NameEdit := 0
        this.EstimateEdit := 0
        this.NoteEdit := 0
        this.ProjectDDL := 0
    }
}

TaskDialogSave(*)
{
    TaskDialog.Save()
}

TaskDialogCancel(*)
{
    TaskDialog.Close()
}

TaskDialogClose(*)
{
    TaskDialog.Close()
}

; ============================================================================
; Projects dialog
; ============================================================================

class ProjectsDialog
{
    static Gui := 0
    static LV := 0
    static RowNames := []
    static NameEdit := 0

    static Open()
    {
        if this.Gui
        {
            this.Refresh()
            this.Gui.Show()
            try WinActivate("ahk_id " this.Gui.Hwnd)
            return
        }

        g := Gui("+Owner" MainUI.Gui.Hwnd, "Projects")
        this.Gui := g
        g.SetFont("s10", "Segoe UI")
        g.Add("Text", "xm y12", "Projects")
        this.LV := g.Add("ListView", "xm y36 w430 h240 Grid -Multi NoSort NoSortHdr", ["Project", "Open tasks", "Sessions"])
        this.LV.ModifyCol(1, 230)
        this.LV.ModifyCol(2, "90 Integer")
        this.LV.ModifyCol(3, "90 Integer")
        this.LV.OnEvent("DoubleClick", ProjectsDoubleClick)

        g.Add("Text", "xm y+12", "New project name")
        this.NameEdit := g.Add("Edit", "xm w300")
        add := g.Add("Button", "x+8 w100 h26", "Add")
        add.OnEvent("Click", ProjectsAdd)
        rename := g.Add("Button", "xm y+12 w100 h30", "Rename")
        rename.OnEvent("Click", ProjectsRename)
        del := g.Add("Button", "x+8 w100 h30", "Delete")
        del.OnEvent("Click", ProjectsDelete)
        close := g.Add("Button", "x+8 w100 h30", "Close")
        close.OnEvent("Click", ProjectsClose)
        g.OnEvent("Close", ProjectsClose)
        g.OnEvent("Escape", ProjectsClose)
        g.Show("w470 h410 Center")
        this.Refresh()
    }

    static Refresh()
    {
        if !this.LV
            return
        this.LV.Opt("-Redraw")
        this.LV.Delete()
        this.RowNames := []
        for p in Store.ProjectNames(false)
        {
            openCount := 0
            sessions := 0
            for t in Store.Tasks
            {
                if (!t["done"] && StrLower(t["project"]) = StrLower(p))
                    openCount += 1
            }
            for r in Store.History
            {
                if (StrLower(r["project"]) = StrLower(p))
                    sessions += 1
            }
            this.LV.Add("", p, openCount, sessions)
            this.RowNames.Push(p)
        }
        this.LV.Opt("+Redraw")
    }

    static SelectedName()
    {
        if !this.LV
            return ""
        row := this.LV.GetNext(0, "Focused")
        if !row
            row := this.LV.GetNext(0, "Selected")
        if (row >= 1 && row <= this.RowNames.Length)
            return this.RowNames[row]
        return ""
    }

    static Add()
    {
        name := Trim(this.NameEdit.Value)
        if !this.ValidNewName(name)
            return
        Store.Projects.Push(name)
        Store.SaveTasks()
        this.NameEdit.Value := ""
        this.Refresh()
        MainUI.RefreshTasks()
    }

    static ValidNewName(Name)
    {
        Name := Trim(Name)
        if (Name = "")
        {
            MsgBox("Enter a project name first.", "Pomodoro", "Icon!")
            return false
        }
        if InStr(Name, "`t") || InStr(Name, "`n") || InStr(Name, "`r")
        {
            MsgBox("Project names cannot contain tabs or line breaks.", "Pomodoro", "Icon!")
            return false
        }
        if Store.HasProject(Name)
        {
            MsgBox("That project already exists.", "Pomodoro", "Icon!")
            return false
        }
        return true
    }

    static Rename()
    {
        oldName := this.SelectedName()
        if (oldName = "")
        {
            MsgBox("Select a project first.", "Pomodoro", "Icon!")
            return
        }
        newName := InputBox("Rename project:", "Rename Project", "w360", oldName)
        if (newName.Result = "Cancel" || newName.Value = "")
            return
        newName := Trim(newName.Value)
        if InStr(newName, "`t") || InStr(newName, "`n") || InStr(newName, "`r")
        {
            MsgBox("Project names cannot contain tabs or line breaks.", "Pomodoro", "Icon!")
            return
        }
        if (StrLower(newName) != StrLower(oldName) && Store.HasProject(newName))
        {
            MsgBox("That project already exists.", "Pomodoro", "Icon!")
            return
        }

        for i, p in Store.Projects
        {
            if (StrLower(p) = StrLower(oldName))
            {
                Store.Projects[i] := newName
                break
            }
        }
        for t in Store.Tasks
        {
            if (StrLower(t["project"]) = StrLower(oldName))
                t["project"] := newName
        }
        for r in Store.History
        {
            if (StrLower(r["project"]) = StrLower(oldName))
                r["project"] := newName
        }
        Store.SaveTasks()
        Store.SaveHistory()
        this.Refresh()
        MainUI.RefreshTasks()
    }

    static Delete()
    {
        name := this.SelectedName()
        if (name = "")
        {
            MsgBox("Select a project first.", "Pomodoro", "Icon!")
            return
        }
        if (MsgBox('Delete project "' name '"? Tasks keep their name but lose the project. History is kept.', "Pomodoro", "YesNo Icon!") != "Yes")
            return
        for i, p in Store.Projects
        {
            if (StrLower(p) = StrLower(name))
            {
                Store.Projects.RemoveAt(i)
                break
            }
        }
        for t in Store.Tasks
        {
            if (StrLower(t["project"]) = StrLower(name))
                t["project"] := ""
        }
        Store.SaveTasks()
        this.Refresh()
        MainUI.RefreshTasks()
    }

    static Close()
    {
        if this.Gui
        {
            try this.Gui.Destroy()
        }
        this.Gui := 0
        this.LV := 0
        this.NameEdit := 0
        this.RowNames := []
    }
}

ProjectsAdd(*)
{
    ProjectsDialog.Add()
}

ProjectsRename(*)
{
    ProjectsDialog.Rename()
}

ProjectsDelete(*)
{
    ProjectsDialog.Delete()
}

ProjectsClose(*)
{
    ProjectsDialog.Close()
}

ProjectsDoubleClick(ctrl, row, *)
{
    ProjectsDialog.Rename()
}

; ============================================================================
; Reports window
; ============================================================================

class ReportsDialog
{
    static Gui := 0
    static Tab := 0
    static FilterDDL := 0
    static FilterNames := []
    static SuppressFilter := false
    static StatHours := 0
    static StatDays := 0
    static StatStreak := 0
    static ChartView := "Week"
    static ChartBars := []
    static ChartLabels := []
    static ChartValueLabels := []
    static ChartMaxLabel := 0
    static ChartZeroLabel := 0
    static ChartAreaX := 70
    static ChartAreaW := 660
    static ChartTopY := 196
    static ChartBaseY := 386
    static PeriodButtons := Map()
    static DetailLV := 0
    static DetailCount := 0
    static RankingLV := 0
    static GroupDDL := 0

    static Open()
    {
        if this.Gui
        {
            this.RefreshAll()
            this.Gui.Show()
            try WinActivate("ahk_id " this.Gui.Hwnd)
            return
        }
        this.Build()
        this.RefreshAll()
        this.Gui.Show("w820 h640 Center")
    }

    static Build()
    {
        g := Gui("+Owner" MainUI.Gui.Hwnd, "Pomodoro Reports")
        this.Gui := g
        g.SetFont("s10", "Segoe UI")

        g.Add("Text", "x20 y16", "Project filter")
        this.FilterDDL := g.Add("DropDownList", "x112 y12 w230", ["All projects"])
        this.FilterDDL.OnEvent("Change", ReportsFilterChanged)

        this.Tab := g.Add("Tab3", "x20 y50 w780 h520", ["Summary", "Detail", "Ranking"])
        this.BuildSummaryTab()
        this.BuildDetailTab()
        this.BuildRankingTab()
        this.Tab.UseTab()

        exportBtn := g.Add("Button", "x20 y586 w150 h34", "Export CSV...")
        exportBtn.OnEvent("Click", ExportHistoryCsv)
        closeBtn := g.Add("Button", "x700 y586 w100 h34", "Close")
        closeBtn.OnEvent("Click", ReportsClose)
        g.SetFont("s9", "Segoe UI")
        g.Add("Text", "x190 y594 w490 h22", "All reports read only the local history.csv file. No network access.")
        g.OnEvent("Close", ReportsClose)
        g.OnEvent("Escape", ReportsClose)
    }

    static BuildSummaryTab()
    {
        g := this.Gui
        this.Tab.UseTab(1)

        g.SetFont("s22 bold", "Segoe UI")
        this.StatHours := g.Add("Text", "x48 y82 w200 h38 Center cBA4949", "0.0")
        this.StatDays := g.Add("Text", "x290 y82 w200 h38 Center c38858A", "0")
        this.StatStreak := g.Add("Text", "x532 y82 w200 h38 Center c397097", "0")
        g.SetFont("s9", "Segoe UI")
        g.Add("Text", "x48 y122 w200 h20 Center c555555", "total hours focused")
        g.Add("Text", "x290 y122 w200 h20 Center c555555", "days accessed")
        g.Add("Text", "x532 y122 w200 h20 Center c555555", "current day streak")

        g.SetFont("s12 bold", "Segoe UI")
        g.Add("Text", "x42 y154 w300 h26 c333333", "Focus time")
        g.SetFont("s9", "Segoe UI")
        this.PeriodButtons["Week"] := g.Add("Button", "x560 y150 w66 h26", "Week")
        this.PeriodButtons["Month"] := g.Add("Button", "x632 y150 w66 h26", "Month")
        this.PeriodButtons["Year"] := g.Add("Button", "x704 y150 w66 h26", "Year")
        for name, btn in this.PeriodButtons
            btn.OnEvent("Click", ReportPeriodClicked.Bind(name))

        this.CreateChartControls()
        this.RefreshChart()
    }

    static CreateChartControls()
    {
        ; There is no built-in way to remove an individual GuiControl, so the
        ; chart uses a fixed pool of 31 reusable bars (the maximum is a month).
        g := this.Gui
        this.ChartBars := []
        this.ChartLabels := []
        this.ChartValueLabels := []
        this.ChartMaxLabel := g.Add("Text", "x42 y176 w130 h20 BackgroundTrans", "Max 0.0h")
        this.ChartMaxLabel.SetFont("s8", "Segoe UI")
        this.ChartZeroLabel := g.Add("Text", "x42 y376 w30 h18 BackgroundTrans", "0h")
        this.ChartZeroLabel.SetFont("s8", "Segoe UI")
        Loop 31
        {
            bar := g.Add("Progress", "x0 y0 w1 h1 Vertical Smooth Range0-100 BackgroundE8ECEF cBA4949 Hidden", 0)
            label := g.Add("Text", "x0 y0 w1 h18 Center BackgroundTrans Hidden", "")
            label.SetFont("s7", "Segoe UI")
            valueLabel := g.Add("Text", "x0 y0 w1 h16 Center BackgroundTrans Hidden", "")
            valueLabel.SetFont("s7", "Segoe UI")
            this.ChartBars.Push(bar)
            this.ChartLabels.Push(label)
            this.ChartValueLabels.Push(valueLabel)
        }
    }

    static BuildDetailTab()
    {
        g := this.Gui
        this.Tab.UseTab(2)
        g.SetFont("s11 bold", "Segoe UI")
        g.Add("Text", "x42 y82 w260 h24 c333333", "Completed focus sessions")
        this.DetailCount := g.Add("Text", "x560 y84 w190 h22 Right c666666", "")
        g.SetFont("s9", "Segoe UI")
        this.DetailLV := g.Add("ListView", "x40 y112 w730 h420 Grid -Multi NoSortHdr", ["Date", "Start", "Task", "Project", "Minutes"])
        this.DetailLV.ModifyCol(1, 95)
        this.DetailLV.ModifyCol(2, 65)
        this.DetailLV.ModifyCol(3, 285)
        this.DetailLV.ModifyCol(4, 165)
        this.DetailLV.ModifyCol(5, "80 Integer")
    }

    static BuildRankingTab()
    {
        g := this.Gui
        this.Tab.UseTab(3)
        g.SetFont("s10", "Segoe UI")
        g.Add("Text", "x42 y82", "Group by")
        this.GroupDDL := g.Add("DropDownList", "x112 y78 w130", ["Project", "Task"])
        this.GroupDDL.Value := 1
        this.GroupDDL.OnEvent("Change", ReportsGroupChanged)
        g.SetFont("s11 bold", "Segoe UI")
        g.Add("Text", "x280 y82 w300 h24 c333333", "Focus ranking")
        g.SetFont("s9", "Segoe UI")
        this.RankingLV := g.Add("ListView", "x40 y112 w730 h420 Grid -Multi NoSortHdr", ["Rank", "Name", "Sessions", "Minutes", "Hours"])
        this.RankingLV.ModifyCol(1, "60 Integer Center")
        this.RankingLV.ModifyCol(2, 340)
        this.RankingLV.ModifyCol(3, "90 Integer")
        this.RankingLV.ModifyCol(4, "100 Integer")
        this.RankingLV.ModifyCol(5, 90)
    }

    static RefreshAll()
    {
        if !this.Gui
            return
        this.RefreshFilter()
        this.RefreshSummary()
        this.RefreshDetail()
        this.RefreshRanking()
    }

    static RefreshFilter()
    {
        old := this.GetFilterProject()
        choices := ["All projects"]
        names := [""]
        for p in Store.ProjectNames(true)
        {
            choices.Push(p)
            names.Push(p)
        }
        this.SuppressFilter := true
        this.FilterDDL.Delete()
        this.FilterDDL.Add(choices)
        this.FilterNames := names
        selected := 1
        for i, p in names
        {
            if (p != "" && StrLower(p) = StrLower(old))
            {
                selected := i
                break
            }
        }
        this.FilterDDL.Value := selected
        this.SuppressFilter := false
    }

    static GetFilterProject()
    {
        if !this.FilterDDL
            return ""
        idx := this.FilterDDL.Value
        if (idx >= 1 && idx <= this.FilterNames.Length)
            return this.FilterNames[idx]
        return ""
    }

    static FilteredHistory()
    {
        project := this.GetFilterProject()
        out := []
        for r in Store.History
        {
            if (project = "" || StrLower(r["project"]) = StrLower(project))
                out.Push(r)
        }
        return out
    }

    static RefreshSummary()
    {
        records := this.FilteredHistory()
        totalMinutes := 0
        days := Map()
        for r in records
        {
            totalMinutes += r["minutes"]
            days[r["date"]] := true
        }
        this.StatHours.Value := Format("{:.1f}", totalMinutes / 60.0)
        this.StatDays.Value := days.Count
        this.StatStreak.Value := CalculateStreak(days)
        this.RefreshChart()
    }

    static RefreshChart()
    {
        if !this.Gui || !this.Tab || this.ChartBars.Length = 0
            return
        this.Tab.UseTab(1)

        for name, btn in this.PeriodButtons
            btn.SetFont(name = this.ChartView ? "s9 bold" : "s9", "Segoe UI")

        data := BuildChartData(this.ChartView, this.FilteredHistory())
        labels := data["labels"]
        values := data["values"]
        maxMinutes := 0
        for v in values
            maxMinutes := Max(maxMinutes, v)

        areaX := this.ChartAreaX
        areaW := this.ChartAreaW
        topY := this.ChartTopY
        baseY := this.ChartBaseY
        barH := baseY - topY
        count := values.Length
        gap := (count > 20) ? 5 : 8
        barW := Min(46, (areaW - gap * Max(0, count - 1)) // Max(1, count))
        totalW := barW * count + gap * Max(0, count - 1)
        startX := areaX + (areaW - totalW) // 2

        this.ChartMaxLabel.Value := "Max " Format("{:.1f}", maxMinutes / 60.0) "h"
        this.ChartZeroLabel.Value := "0h"

        Loop this.ChartBars.Length
        {
            idx := A_Index
            bar := this.ChartBars[idx]
            label := this.ChartLabels[idx]
            valueLabel := this.ChartValueLabels[idx]
            if (idx > count)
            {
                bar.Visible := false
                label.Visible := false
                valueLabel.Visible := false
                continue
            }

            val := values[idx]
            pct := (maxMinutes > 0) ? Round(val / maxMinutes * 100) : 0
            if (val > 0 && pct < 2)
                pct := 2
            x := startX + (idx - 1) * (barW + gap)

            bar.Visible := true
            bar.Move(x, topY, barW, barH)
            bar.Value := pct

            label.Visible := true
            label.Move(x - 3, baseY + 3, barW + 6, 18)
            label.Value := labels[idx]

            if (this.ChartView = "Week" && val > 0)
            {
                valueLabel.Visible := true
                valueLabel.Move(x - 4, topY - 17, barW + 8, 16)
                valueLabel.Value := Format("{:.1f}", val / 60.0)
            }
            else
            {
                valueLabel.Visible := false
            }
        }
        this.Tab.UseTab()
    }

    static RefreshDetail()
    {
        if !this.DetailLV
            return
        records := this.FilteredHistory()
        records := SortHistoryDescending(records)
        this.DetailLV.Opt("-Redraw")
        this.DetailLV.Delete()
        for r in records
        {
            this.DetailLV.Add("",
                r["date"],
                r["start"],
                r["task"] = "" ? "(none)" : r["task"],
                r["project"] = "" ? "-" : r["project"],
                r["minutes"])
        }
        this.DetailLV.Opt("+Redraw")
        this.DetailCount.Value := records.Length " session" (records.Length = 1 ? "" : "s")
    }

    static RefreshRanking()
    {
        if !this.RankingLV
            return
        groupByTask := (this.GroupDDL.Value = 2)
        records := this.FilteredHistory()
        sessions := Map()
        minutes := Map()
        for r in records
        {
            key := groupByTask ? r["task"] : r["project"]
            if (key = "")
                key := groupByTask ? "(No task)" : "(No project)"
            sessions[key] := sessions.Has(key) ? sessions[key] + 1 : 1
            minutes[key] := minutes.Has(key) ? minutes[key] + r["minutes"] : r["minutes"]
        }

        items := []
        for key, mins in minutes
        {
            items.Push(Map(
                "name", key,
                "sessions", sessions[key],
                "minutes", mins
            ))
        }
        SortRankingItems(items)

        this.RankingLV.Opt("-Redraw")
        this.RankingLV.Delete()
        rank := 0
        for item in items
        {
            rank += 1
            this.RankingLV.Add("", rank, item["name"], item["sessions"], item["minutes"], Format("{:.1f}", item["minutes"] / 60.0))
        }
        this.RankingLV.Opt("+Redraw")
    }

    static Close()
    {
        if this.Gui
            try this.Gui.Hide()
    }
}

; ============================================================================
; Reports helpers and handlers
; ============================================================================

ReportsFilterChanged(*)
{
    if ReportsDialog.SuppressFilter
        return
    ReportsDialog.RefreshAll()
}

ReportsGroupChanged(*)
{
    if ReportsDialog.Gui
        ReportsDialog.RefreshRanking()
}

ReportPeriodClicked(Period, *)
{
    ReportsDialog.ChartView := Period
    ReportsDialog.RefreshChart()
}

ReportsClose(*)
{
    ReportsDialog.Close()
    return true
}

ExportHistoryCsv(*)
{
    if ReportsDialog.Gui
        ReportsDialog.Gui.Opt("+OwnDialogs")
    defaultPath := A_Desktop "\pomodoro-history-" FormatTime(A_Now, "yyyyMMdd") ".csv"
    path := FileSelect("S16", defaultPath, "Export focus history", "CSV files (*.csv)")
    if (path = "")
        return
    if !RegExMatch(path, "i)\.csv$")
        path .= ".csv"
    text := "Date,StartTime,Minutes,Task,Project`r`n"
    for r in Store.History
    {
        text .= CsvField(r["date"]) ","
            . CsvField(r["start"]) ","
            . CsvField(r["minutes"]) ","
            . CsvField(r["task"]) ","
            . CsvField(r["project"]) "`r`n"
    }
    try
    {
        f := FileOpen(path, "w", "UTF-8")
        f.Write(text)
        f.Close()
        MsgBox("Exported " Store.History.Length " session" (Store.History.Length = 1 ? "" : "s") " to:`n" path, "Pomodoro Reports", "Iconi")
    }
    catch
    {
        MsgBox("Could not write the CSV file. Check the destination and try again.", "Pomodoro Reports", "Icon!")
    }
}

SortHistoryDescending(Records)
{
    ; Insertion sort: newest date/start first. Histories are normally small.
    items := []
    for r in Records
        items.Push(r)
    n := items.Length
    if (n < 2)
        return items
    i := 2
    while (i <= n)
    {
        current := items[i]
        curKey := current["date"] . current["start"]
        j := i - 1
        while (j >= 1)
        {
            leftKey := items[j]["date"] . items[j]["start"]
            if (StrCompare(leftKey, curKey) >= 0)
                break
            items[j + 1] := items[j]
            j -= 1
        }
        items[j + 1] := current
        i += 1
    }
    return items
}

SortRankingItems(Items)
{
    n := Items.Length
    if (n < 2)
        return
    i := 2
    while (i <= n)
    {
        current := Items[i]
        j := i - 1
        while (j >= 1)
        {
            other := Items[j]
            if (other["minutes"] > current["minutes"])
                break
            if (other["minutes"] = current["minutes"] && StrCompare(StrLower(other["name"]), StrLower(current["name"])) <= 0)
                break
            Items[j + 1] := other
            j -= 1
        }
        Items[j + 1] := current
        i += 1
    }
}

CalculateStreak(DaysMap)
{
    if (DaysMap.Count = 0)
        return 0
    today := FormatTime(A_Now, "yyyy-MM-dd")
    cursor := A_Now
    if !DaysMap.Has(today)
    {
        cursor := DateAdd(A_Now, -1, "Days")
        if !DaysMap.Has(FormatTime(cursor, "yyyy-MM-dd"))
            return 0
    }
    count := 0
    while DaysMap.Has(FormatTime(cursor, "yyyy-MM-dd"))
    {
        count += 1
        cursor := DateAdd(cursor, -1, "Days")
    }
    return count
}

BuildChartData(View, Records)
{
    labels := []
    keys := []
    buckets := Map()
    nowStamp := A_Now

    if (View = "Month")
    {
        year := ToInt(SubStr(nowStamp, 1, 4), 2026)
        month := ToInt(SubStr(nowStamp, 5, 2), 1)
        first := SubStr(nowStamp, 1, 6) "01000000"
        days := DaysInMonth(year, month)
        Loop days
        {
            key := FormatTime(DateAdd(first, A_Index - 1, "Days"), "yyyy-MM-dd")
            keys.Push(key)
            labels.Push(A_Index)
            buckets[key] := 0
        }
    }
    else if (View = "Year")
    {
        year := SubStr(nowStamp, 1, 4)
        months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        Loop 12
        {
            key := year . "-" . Format("{:02}", A_Index)
            keys.Push(key)
            labels.Push(months[A_Index])
            buckets[key] := 0
        }
    }
    else
    {
        offset := Mod(A_WDay + 5, 7)
        start := DateAdd(nowStamp, -offset, "Days")
        Loop 7
        {
            dt := DateAdd(start, A_Index - 1, "Days")
            key := FormatTime(dt, "yyyy-MM-dd")
            keys.Push(key)
            labels.Push(FormatTime(dt, "ddd"))
            buckets[key] := 0
        }
    }

    for r in Records
    {
        key := ""
        if (View = "Month" || View = "Week")
            key := r["date"]
        else
            key := SubStr(r["date"], 1, 7)
        if buckets.Has(key)
            buckets[key] += r["minutes"]
    }

    values := []
    for key in keys
        values.Push(buckets[key])
    return Map("labels", labels, "keys", keys, "values", values)
}

; ============================================================================
; Tray icon and menu
; ============================================================================

SetupTray()
{
    icon := A_ScriptDir "\pomodoro.ico"
    try
    {
        if FileExist(icon)
            TraySetIcon(icon)
        else if (A_IconFile != "")
            TraySetIcon(A_IconFile, A_IconNumber)
    }
    A_IconTip := "Pomodoro"
    tray := A_TrayMenu
    try tray.Delete()
    tray.Add("Show", TrayShow)
    tray.Add("Start/Pause", TrayStartPause)
    tray.Add("Skip", TraySkip)
    tray.Add()
    tray.Add("Settings", TraySettings)
    tray.Add("Reports", TrayReports)
    tray.Add()
    tray.Add("Exit", TrayExit)
    tray.Default := "Show"
}

TrayShow(*)
{
    MainUI.Reveal()
}

TrayStartPause(*)
{
    TimerEngine.Toggle()
}

TraySkip(*)
{
    TimerEngine.SkipPhase()
}

TraySettings(*)
{
    SettingsDialog.Open()
}

TrayReports(*)
{
    ReportsDialog.Open()
}

TrayExit(*)
{
    MainUI.SavePosition()
    ExitApp
}

AppExitHandler(ExitReason, ExitCode)
{
    try
    {
        Store.CaptureWindowPos()
        Store.SaveSettings()
    }
    return 0
}

; ============================================================================
; Settings window
; ============================================================================

class SettingsDialog
{
    static Gui := 0
    static Snapshot := 0
    static AlarmMap := Map()
    static SoundDDL := 0
    static AlarmVolSlider := 0
    static AlarmVolLabel := 0
    static TickVolSlider := 0
    static TickVolLabel := 0
    static PomodoroEdit := 0
    static ShortEdit := 0
    static LongEdit := 0
    static IntervalEdit := 0
    static ReminderMinutesEdit := 0
    static CbBreaks := 0
    static CbPomodoros := 0
    static CbAutoTask := 0
    static CbCloseTray := 0
    static CbAlwaysTop := 0
    static CbDark := 0
    static CbReminder := 0
    static CbTick := 0
    static Rb24 := 0
    static Rb12 := 0
    static ReminderType := 0
    static RepeatDDL := 0
    static TickSpeedDDL := 0

    static Open()
    {
        if this.Gui
        {
            try WinActivate("ahk_id " this.Gui.Hwnd)
            return
        }
        this.Snapshot := Map()
        for key in ["Pomodoro", "ShortBreak", "LongBreak", "LongBreakInterval", "AutoStartBreaks",
            "AutoStartPomodoros", "AutoSwitchTask", "CloseToTray", "AlwaysOnTop", "TimeFormat",
            "DarkWhenRunning", "AlarmSound", "AlarmVolume", "AlarmRepeat", "Ticking", "TickSpeed",
            "TickVolume", "ReminderEnabled", "ReminderType", "ReminderMinutes"]
            this.Snapshot[key] := Store.Settings[key]
        this.Build()
        this.Gui.Show("w620 h560 Center")
    }

    static Build()
    {
        g := Gui("+Owner" MainUI.Gui.Hwnd, "Pomodoro Settings")
        this.Gui := g
        g.SetFont("s10", "Segoe UI")

        tab := g.Add("Tab3", "x15 y15 w590 h445", ["Timer", "Behavior", "Sound && reminders"])
        ; Tab3 child coordinates are client-relative; the page starts below the tabs.
        px := 38
        py := 65

        tab.UseTab(1)
        g.Add("Text", "x" px " y" py, "Pomodoro length (minutes)")
        this.PomodoroEdit := g.Add("Edit", "x300 y" (py - 4) " w80", Store.Get("Pomodoro", 25))
        g.Add("Text", "x" px " y" (py + 42), "Short break (minutes)")
        this.ShortEdit := g.Add("Edit", "x300 y" (py + 38) " w80", Store.Get("ShortBreak", 5))
        g.Add("Text", "x" px " y" (py + 84), "Long break (minutes)")
        this.LongEdit := g.Add("Edit", "x300 y" (py + 80) " w80", Store.Get("LongBreak", 15))
        g.Add("Text", "x" px " y" (py + 126), "Long break after N focus sessions")
        this.IntervalEdit := g.Add("Edit", "x300 y" (py + 122) " w80", Store.Get("LongBreakInterval", 4))
        g.SetFont("s9", "Segoe UI")
        g.Add("Text", "x" px " y" (py + 178) " w500", "A long break is scheduled after this many completed focus sessions.")
        g.Add("Text", "x" px " y" (py + 214) " w500", "Auto-start options are on the Behavior tab.")
        g.SetFont("s10", "Segoe UI")
        tab.UseTab(2)
        this.BuildBehaviorTab(g, px, py)
        tab.UseTab(3)
        this.BuildSoundTab(g, px, py)
        tab.UseTab()

        g.SetFont("s9", "Segoe UI")
        g.Add("Text", "x20 y470 w360 h20", "Changes apply immediately and are saved to disk.")
        g.SetFont("s10", "Segoe UI")
        ok := g.Add("Button", "x410 y490 w80 h32 Default", "OK")
        cancel := g.Add("Button", "x500 y490 w80 h32", "Cancel")
        ok.OnEvent("Click", SettingsOk)
        cancel.OnEvent("Click", SettingsCancel)
        g.OnEvent("Close", SettingsClosed)
        g.OnEvent("Escape", SettingsCancel)

        ; Attach change handlers only after all values are in place.
        for ctrl in [this.PomodoroEdit, this.ShortEdit, this.LongEdit, this.IntervalEdit, this.ReminderMinutesEdit]
            ctrl.OnEvent("Change", SettingsChanged)
        for ctrl in [this.AlarmVolSlider, this.TickVolSlider]
            ctrl.OnEvent("Change", SettingsChanged)
        this.SoundDDL.OnEvent("Change", SoundSelectionChanged)
        this.SoundDDL.OnEvent("Change", SettingsChanged)
    }

    static BuildBehaviorTab(g, px, py)
    {
        this.CbBreaks := g.Add("CheckBox", "x" px " y" py, "Auto-start next break")
        this.CbPomodoros := g.Add("CheckBox", "x" px " y" (py + 29), "Auto-start next pomodoro")
        this.CbAutoTask := g.Add("CheckBox", "x" px " y" (py + 74), "When a task is done, switch to the next unfinished task")
        this.CbCloseTray := g.Add("CheckBox", "x" px " y" (py + 103), "Close button hides the window to the tray")
        this.CbAlwaysTop := g.Add("CheckBox", "x" px " y" (py + 132), "Always on top")
        this.CbDark := g.Add("CheckBox", "x" px " y" (py + 161), "Dim colours while the timer is running")

        g.Add("Text", "x" px " y" (py + 203), "Finish-time display")
        this.Rb24 := g.Add("Radio", "x300 y" (py + 199) " Checked", "24-hour")
        this.Rb12 := g.Add("Radio", "x400 y" (py + 199), "12-hour")

        this.CbReminder := g.Add("CheckBox", "x" px " y" (py + 242), "Enable notification reminder")
        g.Add("Text", "x" px " y" (py + 276), "Remind me")
        this.ReminderType := g.Add("DropDownList", "x170 y" (py + 272) " w180", ["Before the session ends", "After the session starts"])
        this.ReminderMinutesEdit := g.Add("Edit", "x360 y" (py + 272) " w55", Store.Get("ReminderMinutes", 5))
        g.Add("Text", "x422 y" (py + 276), "minutes")
        g.Add("Text", "x" px " y" (py + 314), "Reminder applies to both focus and break timers.")

        this.CbBreaks.Value := Store.Get("AutoStartBreaks", 0)
        this.CbPomodoros.Value := Store.Get("AutoStartPomodoros", 0)
        this.CbAutoTask.Value := Store.Get("AutoSwitchTask", 0)
        this.CbCloseTray.Value := Store.Get("CloseToTray", 1)
        this.CbAlwaysTop.Value := Store.Get("AlwaysOnTop", 0)
        this.CbDark.Value := Store.Get("DarkWhenRunning", 0)
        this.CbReminder.Value := Store.Get("ReminderEnabled", 0)
        this.Rb24.Value := (Store.Get("TimeFormat", "24h") = "24h")
        this.Rb12.Value := (Store.Get("TimeFormat", "24h") = "12h")
        this.ReminderType.Value := (Store.Get("ReminderType", "BeforeEnd") = "AfterStart") ? 2 : 1

        for ctrl in [this.CbBreaks, this.CbPomodoros, this.CbAutoTask, this.CbCloseTray, this.CbAlwaysTop, this.CbDark, this.CbReminder, this.Rb24, this.Rb12]
            ctrl.OnEvent("Click", SettingsChanged)
        this.ReminderType.OnEvent("Change", SettingsChanged)
    }

    static BuildSoundTab(g, px, py)
    {
        g.Add("Text", "x" px " y" py, "Alarm sound")
        this.AlarmMap := Map()
        choices := []
        if FileExist(A_WinDir "\Media")
        {
            Loop Files, A_WinDir "\Media\*.wav"
            {
                name := A_LoopFileName
                if !this.AlarmMap.Has(name)
                {
                    this.AlarmMap[name] := A_LoopFilePath
                    choices.Push(name)
                }
            }
        }
        choices := SortUniqueStrings(choices)
        current := Store.Get("AlarmSound", A_WinDir "\Media\Alarm01.wav")
        found := false
        for name, path in this.AlarmMap
        {
            if (StrLower(path) = StrLower(current))
            {
                found := true
                break
            }
        }
        if !found
        {
            customLabel := "Custom: " current
            choices.Push(customLabel)
            this.AlarmMap[customLabel] := current
        }
        choices.Push("Browse for my own .wav...")
        this.SoundDDL := g.Add("DropDownList", "x150 y" (py - 4) " w330", choices)
        browseBtn := g.Add("Button", "x490 y" (py - 5) " w85 h28", "Browse")
        browseBtn.OnEvent("Click", BrowseAlarmSound)
        ; Select the current sound.
        for name, path in this.AlarmMap
        {
            if (StrLower(path) = StrLower(current))
            {
                this.SoundDDL.Text := name
                break
            }
        }

        g.Add("Text", "x" px " y" (py + 43), "Alarm volume")
        this.AlarmVolSlider := g.Add("Slider", "x150 y" (py + 40) " w300 Range0-100", Store.Get("AlarmVolume", 70))
        this.AlarmVolLabel := g.Add("Text", "x460 y" (py + 43) " w70", Store.Get("AlarmVolume", 70) "%")
        g.Add("Text", "x" px " y" (py + 82), "Repeat alarm")
        this.RepeatDDL := g.Add("DropDownList", "x150 y" (py + 78) " w70", ["1", "2", "3", "4", "5"])
        this.RepeatDDL.Value := ClampInt(Store.Get("AlarmRepeat", 1), 1, 5, 1)
        testBtn := g.Add("Button", "x250 y" (py + 76) " w100 h28", "Test sound")
        testBtn.OnEvent("Click", TestAlarmClicked)

        this.CbTick := g.Add("CheckBox", "x" px " y" (py + 125), "Ticking sound while the timer runs")
        this.CbTick.Value := Store.Get("Ticking", 0)
        g.Add("Text", "x" px " y" (py + 160), "Tick every")
        this.TickSpeedDDL := g.Add("DropDownList", "x150 y" (py + 156) " w120", ["1 second", "2 seconds", "3 seconds"])
        this.TickSpeedDDL.Value := ClampInt(Store.Get("TickSpeed", 1), 1, 3, 1)
        g.Add("Text", "x" px " y" (py + 199), "Tick volume")
        this.TickVolSlider := g.Add("Slider", "x150 y" (py + 196) " w300 Range0-100", Store.Get("TickVolume", 60))
        this.TickVolLabel := g.Add("Text", "x460 y" (py + 199) " w70", Store.Get("TickVolume", 60) "%")
        g.Add("Text", "x" px " y" (py + 238) " w500", "Ticking is silent by default and uses almost no CPU. Turn it off any time.")
        g.SetFont("s9", "Segoe UI")
        g.Add("Text", "x" px " y" (py + 275) " w500", "Volume is applied by writing a scaled temporary copy of the WAV, so the system volume is never changed.")
        g.SetFont("s10", "Segoe UI")

        this.RepeatDDL.OnEvent("Change", SettingsChanged)
        this.TickSpeedDDL.OnEvent("Change", SettingsChanged)
        this.CbTick.OnEvent("Click", SettingsChanged)
    }

    static RefreshLabels()
    {
        if (this.AlarmVolLabel && this.AlarmVolSlider)
            this.AlarmVolLabel.Value := this.AlarmVolSlider.Value "%"
        if (this.TickVolLabel && this.TickVolSlider)
            this.TickVolLabel.Value := this.TickVolSlider.Value "%"
    }

    static ReadValidated(ShowErrors)
    {
        ; Returns a settings Map, or 0 if a visible field is invalid.
        vPomo := ToInt(this.PomodoroEdit.Value, -1)
        vShort := ToInt(this.ShortEdit.Value, -1)
        vLong := ToInt(this.LongEdit.Value, -1)
        vInterval := ToInt(this.IntervalEdit.Value, -1)
        vReminder := ToInt(this.ReminderMinutesEdit.Value, -1)
        if (ShowErrors)
        {
            if (vPomo < 1 || vPomo > 180)
            {
                MsgBox("Pomodoro length must be a whole number from 1 to 180.", "Pomodoro", "Icon!")
                return 0
            }
            if (vShort < 1 || vShort > 60)
            {
                MsgBox("Short break must be a whole number from 1 to 60.", "Pomodoro", "Icon!")
                return 0
            }
            if (vLong < 1 || vLong > 120)
            {
                MsgBox("Long break must be a whole number from 1 to 120.", "Pomodoro", "Icon!")
                return 0
            }
            if (vInterval < 1 || vInterval > 12)
            {
                MsgBox("Long break interval must be a whole number from 1 to 12.", "Pomodoro", "Icon!")
                return 0
            }
            if (vReminder < 1 || vReminder > 180)
            {
                MsgBox("Reminder minutes must be a whole number from 1 to 180.", "Pomodoro", "Icon!")
                return 0
            }
        }

        s := CloneMap(Store.Settings)
        if (vPomo >= 1 && vPomo <= 180)
            s["Pomodoro"] := vPomo
        if (vShort >= 1 && vShort <= 60)
            s["ShortBreak"] := vShort
        if (vLong >= 1 && vLong <= 120)
            s["LongBreak"] := vLong
        if (vInterval >= 1 && vInterval <= 12)
            s["LongBreakInterval"] := vInterval
        if (vReminder >= 1 && vReminder <= 180)
            s["ReminderMinutes"] := vReminder

        s["AutoStartBreaks"] := this.CbBreaks.Value ? 1 : 0
        s["AutoStartPomodoros"] := this.CbPomodoros.Value ? 1 : 0
        s["AutoSwitchTask"] := this.CbAutoTask.Value ? 1 : 0
        s["CloseToTray"] := this.CbCloseTray.Value ? 1 : 0
        s["AlwaysOnTop"] := this.CbAlwaysTop.Value ? 1 : 0
        s["DarkWhenRunning"] := this.CbDark.Value ? 1 : 0
        s["TimeFormat"] := this.Rb12.Value ? "12h" : "24h"
        s["ReminderEnabled"] := this.CbReminder.Value ? 1 : 0
        s["ReminderType"] := (this.ReminderType.Value = 2) ? "AfterStart" : "BeforeEnd"

        s["AlarmVolume"] := this.AlarmVolSlider.Value
        s["AlarmRepeat"] := ClampInt(this.RepeatDDL.Text, 1, 5, 1)
        soundPath := this.AlarmMap.Has(this.SoundDDL.Text) ? this.AlarmMap[this.SoundDDL.Text] : s["AlarmSound"]
        if (soundPath != "" && FileExist(soundPath))
            s["AlarmSound"] := soundPath
        s["Ticking"] := this.CbTick.Value ? 1 : 0
        s["TickSpeed"] := ClampInt(this.TickSpeedDDL.Value, 1, 3, 1)
        s["TickVolume"] := this.TickVolSlider.Value
        return s
    }

    static ApplyInstant()
    {
        if !this.Gui
            return
        this.RefreshLabels()
        s := this.ReadValidated(false)
        if !s
            return
        changed := false
        for k, v in s
        {
            if (Store.Settings[k] != v)
            {
                Store.Settings[k] := v
                changed := true
            }
        }
        if changed
        {
            Store.SaveSettings()
            ApplyLiveSettings()
        }
    }

    static Commit()
    {
        s := this.ReadValidated(true)
        if !s
            return false
        for k, v in s
            Store.Settings[k] := v
        Store.SaveSettings()
        ApplyLiveSettings()
        return true
    }

    static Cancel()
    {
        if !this.Snapshot
        {
            this.Close()
            return
        }
        for k, v in this.Snapshot
            Store.Settings[k] := v
        Store.SaveSettings()
        ApplyLiveSettings()
        this.Close()
    }

    static Close()
    {
        if this.Gui
        {
            try this.Gui.Destroy()
        }
        this.Gui := 0
        this.Snapshot := 0
        this.AlarmMap := Map()
    }

    static BrowseSound()
    {
        this.Gui.Opt("+OwnDialogs")
        path := FileSelect(3,, "Choose an alarm sound", "WAV files (*.wav)")
        if (path = "")
        {
            ; Restore the dropdown to the currently saved sound.
            current := Store.Get("AlarmSound", "")
            for label, savedPath in this.AlarmMap
            {
                if (StrLower(savedPath) = StrLower(current))
                {
                    this.SoundDDL.Text := label
                    break
                }
            }
            return ""
        }
        if !FileExist(path)
            return ""
        label := "Custom: " path
        existed := this.AlarmMap.Has(label)
        this.AlarmMap[label] := path
        if !existed
            this.SoundDDL.Add([label])
        this.SoundDDL.Text := label
        this.ApplyInstant()
        return path
    }
}

; ============================================================================
; Settings handlers and live application
; ============================================================================

ApplyLiveSettings()
{
    if !MainUI.Gui
        return
    if Store.Get("AlwaysOnTop", 0)
        MainUI.Gui.Opt("+AlwaysOnTop")
    else
        MainUI.Gui.Opt("-AlwaysOnTop")
    TimerEngine.OnSettingsChanged()
}

SettingsChanged(*)
{
    if SettingsDialog.Gui
        SettingsDialog.ApplyInstant()
}

SoundSelectionChanged(*)
{
    if !SettingsDialog.Gui
        return
    if (SettingsDialog.SoundDDL.Text = "Browse for my own .wav...")
        SettingsDialog.BrowseSound()
}

BrowseAlarmSound(*)
{
    if SettingsDialog.Gui
        SettingsDialog.BrowseSound()
}

SettingsOk(*)
{
    if SettingsDialog.Commit()
        SettingsDialog.Close()
}

SettingsCancel(*)
{
    SettingsDialog.Cancel()
}

SettingsClosed(*)
{
    ; Changes are already applied; closing with X keeps them, like OK.
    SettingsDialog.Close()
}

TestAlarmClicked(*)
{
    if SettingsDialog.Gui
    {
        SettingsDialog.RefreshLabels()
        candidate := SettingsDialog.ReadValidated(false)
        if candidate
        {
            ; Test the values currently visible without committing the form.
            oldVol := Store.Get("AlarmVolume", 70)
            oldRepeat := Store.Get("AlarmRepeat", 1)
            oldSound := Store.Get("AlarmSound", "")
            Store.Set("AlarmVolume", candidate["AlarmVolume"])
            Store.Set("AlarmRepeat", 1)
            Store.Set("AlarmSound", candidate["AlarmSound"])
            AlarmPlayer.Play(true)
            Store.Set("AlarmVolume", oldVol)
            Store.Set("AlarmRepeat", oldRepeat)
            Store.Set("AlarmSound", oldSound)
            return
        }
    }
    AlarmPlayer.Play(true)
}

; ============================================================================
; Self-test (run: AutoHotkey64.exe pomodoro.ahk --selftest)
; ============================================================================

RunSelfTest()
{
    errors := []
    roundTrip := UnescapeField(EscapeField("a`tb`nc`rd\e"))
    if (roundTrip != "a`tb`nc`rd\e")
        errors.Push("field escaping round-trip failed")

    csvText := "A,B`r`n" . CsvField('x,y') . "," . CsvField('say "hi"') . "`r`n"
    csvRows := ParseCsv(csvText)
    if (csvRows.Length != 2 || csvRows[2][1] != "x,y" || csvRows[2][2] != 'say "hi"')
        errors.Push("CSV parser failed")

    tempDir := A_Temp "\PomodoroAppSelfTest_" A_TickCount
    Store.Init(tempDir)
    Store.Set("Pomodoro", 33)
    Store.Set("AlarmVolume", 55)
    Store.Projects := ["Alpha"]
    Store.Tasks := [Map(
        "id", 1,
        "name", "Write `test",
        "estimate", 4,
        "completed", 2,
        "done", 0,
        "project", "Alpha",
        "note", "line one`nline two",
        "created", A_Now
    )]
    Store.Templates := [Map(
        "id", 1,
        "name", "Template",
        "estimate", 2,
        "project", "Alpha",
        "note", "note"
    )]
    Store.SaveSettings()
    Store.SaveTasks()
    Store.AddHistory("2026-01-02", "09:15", 25, 'Task, "quoted"', "Alpha")
    Store.LoadSettings()
    Store.LoadTasks()
    Store.LoadHistory()
    if (Store.Get("Pomodoro", 0) != 33 || Store.Get("AlarmVolume", 0) != 55)
        errors.Push("settings round-trip failed")
    if (Store.Tasks.Length != 1 || Store.Tasks[1]["name"] != "Write `test" || Store.Tasks[1]["note"] != "line one`nline two")
        errors.Push("tasks round-trip failed (count=" Store.Tasks.Length
            . ", name=[" (Store.Tasks.Length ? Store.Tasks[1]["name"] : "") "]"
            . ", note=[" (Store.Tasks.Length ? Store.Tasks[1]["note"] : "") "])")
    if (Store.Projects.Length != 1 || Store.Projects[1] != "Alpha" || Store.Templates.Length != 1)
        errors.Push("projects/templates round-trip failed (projects=" Store.Projects.Length
            . ", templates=" Store.Templates.Length ")" )
    if (Store.History.Length != 1 || Store.History[1]["task"] != 'Task, "quoted"')
        errors.Push("history round-trip failed")

    if (AtomicWriteText(tempDir "\atomic.txt", "one") != true)
        errors.Push("atomic write failed")
    if (ReadTextFile(tempDir "\atomic.txt") != "one")
        errors.Push("atomic read failed")

    SoundScaler.Init(tempDir)
    originalWav := A_WinDir "\Media\Alarm01.wav"
    scaled := SoundScaler.Prepare(originalWav, 40)
    if (scaled = "" || scaled = originalWav || !FileExist(scaled) || FileGetSize(scaled) < 44)
        errors.Push("WAV volume scaler failed: " SoundScaler.LastError)

    chart := BuildChartData("Week", Store.History)
    if (chart["values"].Length != 7)
        errors.Push("week chart data failed")
    monthChart := BuildChartData("Month", Store.History)
    expectedDays := DaysInMonth(ToInt(SubStr(A_Now, 1, 4)), ToInt(SubStr(A_Now, 5, 2)))
    if (monthChart["values"].Length != expectedDays)
        errors.Push("month chart data failed")
    yearChart := BuildChartData("Year", Store.History)
    if (yearChart["values"].Length != 12)
        errors.Push("year chart data failed")
    if (yearChart["values"][1] != 25)
        errors.Push("year chart values failed")

    ranking := [Map("name", "B", "minutes", 25), Map("name", "A", "minutes", 50)]
    SortRankingItems(ranking)
    if (ranking[1]["name"] != "A" || ranking[2]["name"] != "B")
        errors.Push("ranking sort failed")
    sortedHistory := SortHistoryDescending(Store.History)
    if (sortedHistory.Length != 1)
        errors.Push("history sort failed")

    streakDays := Map()
    streakDays[FormatTime(A_Now, "yyyy-MM-dd")] := true
    if (CalculateStreak(streakDays) != 1)
        errors.Push("streak calculation failed")

    if (errors.Length > 0)
    {
        FileAppend("SELFTEST FAIL`n", "*")
        for e in errors
            FileAppend("- " e "`n", "*")
        ExitApp(1)
    }
    FileAppend("SELFTEST PASS`n", "*")
    ExitApp(0)
}
