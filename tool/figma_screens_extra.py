"""The remaining 34 screens for the Figma sheet.

Split out of `figma_sheet.py` so the main file stays readable. Each function
takes the palette and returns one `Screen`.
"""

from __future__ import annotations

from figma_sheet import H, W, Screen, circle, icon, line, rect, text


def remaining(p) -> list[Screen]:
    out: list[Screen] = []

    # Splash ---------------------------------------------------------------
    s = Screen("splash", "Splash", "Wordmark, one progress bar, retry", palette=p)
    s.parts.append(rect(0, 0, W, H, p.bg, rx=20, stroke=p.hairline))
    s.agent_mark(W / 2, 300, 36)
    s.parts.append(text(W / 2, 386, "Ovid Si", 28, p.text, anchor="middle", weight=600))
    s.parts.append(rect(W / 2 - 60, 430, 120, 3, p.hairline, rx=2))
    s.parts.append(rect(W / 2 - 60, 430, 46, 3, p.text, rx=2))
    s.parts.append(text(W / 2, 462, "Loading your chats", 12, p.faint, anchor="middle"))
    out.append(s)

    # Sign in --------------------------------------------------------------
    s = Screen("sign_in", "Sign in", "Google and phone only", palette=p)
    s.parts.append(rect(0, 0, W, H, p.bg, rx=20, stroke=p.hairline))
    s.agent_mark(W / 2, 230, 30)
    s.parts.append(text(W / 2, 300, "Welcome back", 24, p.text, anchor="middle", weight=600))
    s.parts.append(text(W / 2, 326, "Pick up where you left off.", 13, p.muted, anchor="middle"))
    s.button(24, 400, W - 48, "Continue with Google")
    s.parts.append(rect(24, 462, W - 48, 48, p.bg, rx=12, stroke=p.hairline))
    s.parts.append(text(W / 2, 492, "Continue with phone", 14.5, p.text, anchor="middle", weight=600))
    s.parts.append(text(W / 2, H - 40, "Privacy · Terms", 11.5, p.faint, anchor="middle"))
    out.append(s)

    # Language & goal ------------------------------------------------------
    s = Screen("language_goal", "Language & goal", "Chips, then one Continue", palette=p)
    s.header("Language & goal")
    y = s.section(84, "Spoken language")
    x = 16
    for label, sel in [("English", True), ("Hindi", False), ("Hinglish", False)]:
        x = s.chip(x, y, label, selected=sel)
    y += 48
    y = s.section(y, "First goal")
    for label, sel in [("Build and ship", True), ("Research", False), ("Automate my work", False)]:
        s.parts.append(
            rect(16, y, W - 32, 44, p.surface_alt if sel else p.bg, rx=12,
                 stroke=None if sel else p.hairline)
        )
        s.parts.append(text(32, y + 27, label, 13.5, p.text))
        if sel:
            s.parts.append(icon("check", W - 44, y + 12, 20, p.text))
        y += 52
    s.button(24, H - 96, W - 48, "Continue")
    out.append(s)

    # Model chip menu ------------------------------------------------------
    s = Screen("model_chip", "Model chip menu", "Popover · Auto plus recent", palette=p)
    s.parts.append(rect(0, 0, W, H, p.bg, rx=20, stroke=p.hairline))
    s.parts.append(rect(16, 16, 160, 30, p.surface_alt, rx=15, stroke=p.hairline))
    s.parts.append(text(32, 36, "Auto", 12.5, p.text, weight=500))
    s.parts.append(icon("chevron", 152, 22, 18, p.muted))
    s.card(16, 58, W - 32, 132)
    s.parts.append(rect(16, 58, 2, 132, p.agent))
    s.parts.append(text(32, 84, "Auto", 14, p.text, weight=600))
    s.parts.append(text(32, 104, "Routes each request", 11.5, p.muted))
    s.parts.append(icon("check", W - 46, 76, 20, p.text))
    s.parts.append(line(32, 122, W - 16, 122, p.hairline))
    s.parts.append(text(32, 148, "Ovid 2 Pro", 13.5, p.text))
    s.parts.append(text(32, 168, "Manual · Plus and up", 11.5, p.faint))
    out.append(s)

    # System states --------------------------------------------------------
    s = Screen("system_states", "System states", "One tile per state", palette=p)
    s.header("System states")
    yy = 84
    for title, body, danger in [
        ("You're offline", "Ovid will retry when the connection returns.", False),
        ("Allowance used", "Resets in 9 hours. Upgrade for more.", False),
        ("Account blocked", "Suspicious activity detected. Check your email.", True),
    ]:
        s.card(16, yy, W - 32, 88)
        s.parts.append(circle(38, yy + 26, 5, p.agent if danger else p.muted))
        s.parts.append(text(56, yy + 30, title, 14, p.text, weight=600))
        s.parts.append(text(56, yy + 52, body[:40], 12, p.muted))
        s.parts.append(text(56, yy + 70, body[40:80], 12, p.muted))
        yy += 100
    out.append(s)

    # Projects -------------------------------------------------------------
    s = Screen("projects", "Projects", "Name, chats, per-project memory", palette=p)
    s.header("Projects", actions=["plus"])
    yy = 80
    for name, meta, shared in [
        ("Ovid Si", "12 chats · 4 files", False),
        ("Portfolio", "3 chats · 1 file", True),
        ("Client work", "8 chats", False),
    ]:
        s.card(16, yy, W - 32, 84)
        s.parts.append(icon("folder", 30, yy + 18, 22, p.muted))
        s.parts.append(text(62, yy + 28, name, 14.5, p.text, weight=600))
        s.parts.append(text(62, yy + 48, meta, 11.5, p.muted))
        if shared:
            s.parts.append(rect(W - 88, yy + 18, 56, 22, p.surface_alt, rx=11))
            s.parts.append(text(W - 60, yy + 33, "Shared", 10, p.faint, anchor="middle"))
        yy += 96
    out.append(s)

    # Chat actions ---------------------------------------------------------
    s = Screen("session_actions", "Chat actions", "Sheet · share, rename, pin, delete", palette=p)
    s.parts.append(rect(0, 0, W, H, p.bg, rx=20, stroke=p.hairline))
    s.parts.append(rect(W / 2 - 18, 12, 36, 4, p.hairline, rx=2))
    s.parts.append(text(16, 48, "Auth token refresh", 16, p.text, weight=600))
    s.parts.append(text(16, 66, "12 messages · 2h ago", 11.5, p.muted))
    s.parts.append(icon("dots", W - 40, 34, 22, p.muted))
    y = 88
    for label, ic in [
        ("Share chat", "share"), ("Rename", "file"), ("Add to project", "folder"),
        ("Pin chat", "pin"), ("Export as Markdown", "file"), ("Delete chat", "trash"),
    ]:
        danger = label.startswith("Delete")
        s.parts.append(icon(ic, 20, y + 10, 20, p.agent if danger else p.muted))
        s.parts.append(text(52, y + 26, label, 14, p.agent if danger else p.text))
        s.parts.append(line(16, y + 44, W, y + 44, p.hairline))
        y += 46
    out.append(s)

    # Repo picker ----------------------------------------------------------
    s = Screen("repo_picker", "Repo picker", "Searchable repos, then a branch", palette=p)
    s.header("Repositories")
    s.parts.append(rect(16, 72, W - 32, 40, p.surface, rx=10, stroke=p.hairline))
    s.parts.append(icon("search", 28, 81, 20, p.faint))
    s.parts.append(text(56, 97, "Search repositories", 13, p.faint))
    yy = 128
    for name, meta, sel in [
        ("aasheesh/ovid-app", "Flutter · private", True),
        ("aasheesh/portfolio", "React · public", False),
        ("aasheesh/api", "Go · private", False),
    ]:
        s.parts.append(icon("folder", 16, yy + 8, 20, p.muted))
        s.parts.append(text(44, yy + 22, name, 13.5, p.text))
        s.parts.append(text(44, yy + 40, meta, 11, p.faint))
        if sel:
            s.parts.append(icon("check", W - 42, yy + 16, 20, p.text))
        s.parts.append(line(16, yy + 52, W, yy + 52, p.hairline))
        yy += 56
    s.button(16, H - 88, W - 32, "Choose branch")
    out.append(s)

    # Branch picker --------------------------------------------------------
    s = Screen("branch_picker", "Branch picker", "Search, switch, create", palette=p)
    s.parts.append(rect(0, 0, W, H, p.bg, rx=20, stroke=p.hairline))
    s.parts.append(rect(W / 2 - 18, 12, 36, 4, p.hairline, rx=2))
    s.parts.append(text(16, 48, "Switch branch", 16, p.text, weight=600))
    s.parts.append(icon("dots", W - 40, 34, 22, p.muted))
    s.parts.append(rect(16, 68, W - 32, 40, p.surface, rx=10, stroke=p.hairline))
    s.parts.append(icon("search", 28, 77, 20, p.faint))
    s.parts.append(text(56, 93, "Search branches", 13, p.faint))
    yy = 124
    for name, sel in [("main", True), ("feat/ui-v2", False), ("fix/auth-token", False), ("chore/deps", False)]:
        s.parts.append(text(20, yy + 22, name, 13.5, p.text))
        if sel:
            s.parts.append(icon("check", W - 42, yy + 10, 20, p.text))
        s.parts.append(line(16, yy + 38, W, yy + 38, p.hairline))
        yy += 44
    s.button(16, H - 88, W - 32, "Create branch", primary=False)
    out.append(s)

    # Changes --------------------------------------------------------------
    s = Screen("changes", "Changes & diff", "Rows with +N −N, inline diff", palette=p)
    s.header("Changes", actions=["check"])
    yy = 76
    for path, add, rem, open_ in [
        ("lib/core/auth.dart", "+14", "−6", True),
        ("lib/ui/chat.dart", "+42", "−18", False),
        ("pubspec.yaml", "+1", "−0", False),
    ]:
        s.parts.append(text(16, yy + 20, path, 13, p.text))
        s.parts.append(text(W - 52, yy + 20, add, 11.5, p.text, anchor="end"))
        s.parts.append(text(W - 16, yy + 20, rem, 11.5, p.faint, anchor="end"))
        s.parts.append(icon("chevron", W - 40, yy + 8, 16, p.faint))
        s.parts.append(line(16, yy + 32, W, yy + 32, p.hairline))
        yy += 36
        if open_:
            for i in range(5):
                bg = p.surface_alt if i < 3 else p.bg
                s.parts.append(rect(16, yy, W - 32, 20, bg))
                prefix = "+" if i < 3 else "−"
                s.parts.append(text(26, yy + 14, prefix + "  token = refresh()", 10.5, p.text))
                yy += 20
            yy += 8
    out.append(s)

    # Live preview ---------------------------------------------------------
    s = Screen("live_preview", "Live preview", "Frame fills, one status pill", palette=p)
    s.header("Live preview", actions=["clock"])
    s.parts.append(rect(16, 72, W - 32, 400, p.surface_alt, rx=12, stroke=p.hairline))
    s.parts.append(text(40, 128, "Ovid", 26, p.text, weight=700))
    s.parts.append(text(40, 152, "Your always-on agent", 13, p.muted))
    s.parts.append(rect(40, 180, W - 120, 34, p.surface, rx=8, stroke=p.hairline))
    s.parts.append(text(54, 202, "Build a landing page", 12, p.text))
    s.parts.append(rect(W / 2 - 60, 440, 120, 30, p.text, rx=15))
    s.parts.append(text(W / 2, 460, "Try Ovid", 12, p.bg, anchor="middle", weight=600))
    s.parts.append(rect(28, 84, 74, 24, p.bg, rx=12, stroke=p.hairline))
    s.parts.append(text(65, 100, "Online", 10.5, p.text, anchor="middle"))
    s.parts.append(text(16, 496, "ovid.ai/preview", 11, p.faint))
    s.parts.append(text(W - 16, 496, "28 min left", 11, p.faint, anchor="end"))
    out.append(s)

    # Take control ---------------------------------------------------------
    s = Screen("take_control", "Take control", "One title, one line, two buttons", palette=p)
    s.parts.append(rect(0, 0, W, H, p.bg, rx=20, stroke=p.hairline))
    s.parts.append(rect(W / 2 - 18, 12, 36, 4, p.hairline, rx=2))
    s.parts.append(text(W / 2, 120, "Take control", 20, p.text, anchor="middle", weight=600))
    s.parts.append(text(W / 2, 148, "Tap, type and scroll. Ovid pauses.", 12.5, p.muted, anchor="middle"))
    s.button(24, 190, W - 48, "Start controlling")
    s.parts.append(rect(24, 250, W - 48, 48, p.bg, rx=12, stroke=p.hairline))
    s.parts.append(text(W / 2, 280, "Stay watching", 14.5, p.text, anchor="middle", weight=600))
    out.append(s)

    # Connector detail -----------------------------------------------------
    s = Screen("connector_detail", "Connector detail", "Status, test, permissions", palette=p)
    s.header("GitHub", actions=["dots"])
    s.parts.append(rect(16, 72, W - 32, 72, p.surface, rx=12, stroke=p.hairline))
    s.parts.append(icon("plus", 32, 92, 24, p.muted))
    s.parts.append(text(68, 104, "GitHub", 15, p.text, weight=600))
    s.parts.append(text(68, 124, "Connected · 2 min ago", 11.5, p.muted))
    s.parts.append(rect(W - 56, 92, 40, 22, p.text, rx=11))
    s.parts.append(circle(W - 27, 103, 9, p.bg))
    s.button(16, 164, W - 32, "Test connection", primary=False)
    yy = s.section(232, "Permissions")
    for label, on in [("Read files", True), ("Write files", True), ("Run commands", False)]:
        s.parts.append(text(16, yy + 22, label, 13.5, p.text))
        s.parts.append(rect(W - 56, yy + 10, 40, 22, p.text if on else p.surface_alt, rx=11))
        s.parts.append(circle(W - 27 if on else W - 45, yy + 21, 9, p.bg if on else p.muted))
        yy += 44
    s.parts.append(text(W / 2, H - 60, "Disconnect", 13, p.agent, anchor="middle"))
    out.append(s)

    # Add connector --------------------------------------------------------
    s = Screen("add_connector", "Add connector", "Name, URL, key, permissions", palette=p)
    s.header("Add connector", actions=["check"])
    yy = 84
    for label, value in [("Name", "GitHub"), ("Server URL", "https://api.github.com")]:
        s.parts.append(text(16, yy, label, 11.5, p.faint))
        s.parts.append(rect(16, yy + 8, W - 32, 44, p.surface, rx=10, stroke=p.hairline))
        s.parts.append(text(32, yy + 36, value, 13, p.text))
        yy += 68
    s.parts.append(text(16, yy, "API key", 11.5, p.faint))
    s.parts.append(rect(16, yy + 8, W - 32, 44, p.surface, rx=10, stroke=p.hairline))
    s.parts.append(text(32, yy + 36, "••••••••••••", 13, p.text))
    yy = s.section(yy + 76, "Permissions")
    for label, on in [("Read files", True), ("Write files", False), ("Run commands", False)]:
        s.parts.append(text(16, yy + 22, label, 13.5, p.text))
        s.parts.append(rect(W - 56, yy + 10, 40, 22, p.text if on else p.surface_alt, rx=11))
        s.parts.append(circle(W - 27 if on else W - 45, yy + 21, 9, p.bg if on else p.muted))
        yy += 44
    s.button(16, H - 88, W - 32, "Save connector")
    out.append(s)

    # Schedule editor ------------------------------------------------------
    s = Screen("schedule_editor", "Schedule editor", "Prompt, cadence, time, save", palette=p)
    s.header("New schedule", actions=["dots"])
    s.parts.append(text(16, 84, "Prompt", 11.5, p.faint))
    s.parts.append(rect(16, 92, W - 32, 88, p.surface, rx=10, stroke=p.hairline))
    s.parts.append(text(32, 118, "Check my Delhi train and", 13, p.text))
    s.parts.append(text(32, 138, "find a cheap hotel.", 13, p.text))
    yy = s.section(200, "Cadence")
    x = 16
    for label, sel in [("Daily", True), ("Weekly", False), ("Custom", False)]:
        x = s.chip(x, yy, label, selected=sel)
    yy += 52
    s.parts.append(text(16, yy, "Run at", 11.5, p.faint))
    s.parts.append(rect(16, yy + 8, W - 32, 44, p.surface, rx=10, stroke=p.hairline))
    s.parts.append(text(32, yy + 36, "09:00", 13, p.text))
    s.parts.append(text(16, yy + 76, "Asia/Kolkata", 11.5, p.faint))
    s.button(16, H - 88, W - 32, "Save schedule")
    out.append(s)

    # Schedule runs --------------------------------------------------------
    s = Screen("schedule_runs", "Schedule runs", "Summary line, day timeline", palette=p)
    s.header("Delhi train check", actions=["dots"])
    s.parts.append(text(16, 84, "95.8 % · 24 runs", 13, p.text, weight=600))
    yy = 116
    for day, runs in [
        ("Today", [("09:00", "Completed", "12 s")]),
        ("Mon 20", [("09:00", "Failed", "4 s")]),
    ]:
        s.parts.append(text(16, yy, day.upper(), 10.5, p.faint, weight=600, letter_spacing=0.8))
        yy += 20
        for t, status, dur in runs:
            s.parts.append(circle(22, yy + 10, 4, p.agent if status == "Failed" else p.text))
            s.parts.append(text(36, yy + 14, t, 12.5, p.text))
            s.parts.append(text(76, yy + 14, status, 11.5, p.muted))
            s.parts.append(text(W - 16, yy + 14, dur, 11.5, p.faint, anchor="end"))
            yy += 30
        yy += 10
    out.append(s)

    # Shared chat ----------------------------------------------------------
    s = Screen("share_chat", "Shared chat", "Read-only transcript, fork", palette=p)
    s.header("Shared chat", actions=["dots"])
    s.parts.append(rect(16, 72, W - 32, 26, p.surface_alt, rx=13))
    s.parts.append(text(30, 89, "Read only · can fork", 11, p.muted))
    s.parts.append(rect(96, 116, W - 112, 44, p.surface_alt, rx=14))
    s.parts.append(text(112, 143, "Add dark mode to settings", 13, p.text))
    s.parts.append(text(16, 190, "Done. I added a theme toggle to", 13.5, p.text))
    s.parts.append(text(16, 210, "Appearance and wired it to the", 13.5, p.text))
    s.parts.append(text(16, 230, "system setting.", 13.5, p.text))
    s.button(16, H - 88, W - 32, "Fork into my account")
    out.append(s)

    # Collab live ----------------------------------------------------------
    s = Screen("collab_live", "Collaboration live", "Turn banner, gated composer", palette=p)
    s.header("Ovid Si · 4 here", actions=["user"])
    s.parts.append(rect(16, 72, W - 32, 40, p.surface_alt, rx=10))
    s.parts.append(circle(34, 92, 5, p.agent))
    s.parts.append(text(48, 96, "Aasheesh has the turn · 0:42", 12, p.text))
    s.parts.append(rect(96, 128, W - 112, 44, p.surface_alt, rx=14))
    s.parts.append(text(112, 155, "Let's rename the auth module", 13, p.text))
    s.parts.append(text(16, 202, "Renamed auth_service.dart and", 13.5, p.text))
    s.parts.append(text(16, 222, "updated every import.", 13.5, p.text))
    s.composer(H - 88, "Wait for your turn")
    out.append(s)

    # Collab members -------------------------------------------------------
    s = Screen("collab_members", "Collaboration members", "Avatar, name, role, remove", palette=p)
    s.header("Members", actions=["plus"])
    s.parts.append(text(16, 84, "4 of 50", 12, p.muted))
    yy = 108
    for name, role, owner in [
        ("Aasheesh", "Owner", True), ("Priya", "Editor", False),
        ("Rohan", "Editor", False), ("Meera", "Viewer", False),
    ]:
        s.parts.append(circle(34, yy + 22, 16, p.surface_alt))
        s.parts.append(text(34, yy + 27, name[0], 13, p.text, anchor="middle", weight=600))
        s.parts.append(text(60, yy + 20, name, 13.5, p.text))
        s.parts.append(text(60, yy + 38, role, 11, p.faint))
        if owner:
            s.parts.append(rect(W - 72, yy + 12, 40, 20, p.surface_alt, rx=10))
            s.parts.append(text(W - 52, yy + 26, "You", 9.5, p.faint, anchor="middle"))
        else:
            s.parts.append(icon("dots", W - 42, yy + 12, 20, p.muted))
        s.parts.append(line(16, yy + 56, W, yy + 56, p.hairline))
        yy += 58
    s.parts.append(text(W / 2, H - 60, "Leave chat", 13, p.agent, anchor="middle"))
    out.append(s)

    # Trajectory -----------------------------------------------------------
    s = Screen("trajectory", "Run trajectory", "Ordered steps with durations", palette=p)
    s.header("Trajectory", actions=["share"])
    yy = 84
    steps = [
        ("Read the failing test", "0.4 s", True),
        ("Search the workspace", "1.2 s", True),
        ("Dispatch 3 subagents", "8.4 s", True),
        ("Apply the fix", "2.1 s", True),
        ("Run the suite", "…", False),
    ]
    for idx, (title, dur, done) in enumerate(steps):
        s.parts.append(icon("check" if done else "clock", 16, yy + 2, 18, p.text if done else p.muted))
        s.parts.append(text(44, yy + 16, title, 13.5, p.text))
        s.parts.append(text(W - 16, yy + 16, dur, 11.5, p.faint, anchor="end"))
        if idx < len(steps) - 1:
            s.parts.append(line(25, yy + 24, 25, yy + 44, p.hairline))
        yy += 44
    out.append(s)

    # Subagent -------------------------------------------------------------
    s = Screen("subagent", "Subagent", "Status, five fields, one log action", palette=p)
    s.header("Subagent", actions=["dots"])
    s.parts.append(text(16, 84, "Refactor auth guard", 12, p.muted))
    s.parts.append(rect(16, 96, 88, 26, p.surface_alt, rx=13))
    s.parts.append(circle(32, 109, 4, p.agent))
    s.parts.append(text(44, 113, "Completed", 11, p.text))
    yy = 146
    for k, v in [
        ("Status", "completed"), ("Files modified", "2"), ("Artifacts", "0"),
        ("Key findings", "Token refresh guarded"), ("Error", "none"),
    ]:
        s.parts.append(text(16, yy, k, 11, p.faint))
        s.parts.append(text(16, yy + 18, v[:40], 13, p.text))
        yy += 40
    s.button(16, yy + 12, W - 32, "View log", primary=False)
    out.append(s)

    # Account --------------------------------------------------------------
    s = Screen("account", "Account", "Avatar, plan, four rows", palette=p)
    s.header("Account")
    s.parts.append(circle(W / 2, 132, 34, p.surface_alt))
    s.parts.append(text(W / 2, 141, "A", 26, p.text, anchor="middle", weight=600))
    s.parts.append(text(W / 2, 190, "Aasheesh Singh", 17, p.text, anchor="middle", weight=600))
    s.parts.append(rect(W / 2 - 36, 204, 72, 22, p.surface_alt, rx=11))
    s.parts.append(text(W / 2, 219, "Ovid Plus", 10.5, p.muted, anchor="middle"))
    yy = 250
    for label, ic in [
        ("Edit profile", "user"), ("Sign-in methods", "key"),
        ("Data control", "file"), ("Delete account", "trash"),
    ]:
        danger = label.startswith("Delete")
        s.parts.append(icon(ic, 16, yy + 12, 20, p.agent if danger else p.muted))
        s.parts.append(text(52, yy + 28, label, 14, p.agent if danger else p.text))
        s.parts.append(icon("chevron", W - 40, yy + 14, 18, p.faint))
        s.parts.append(line(16, yy + 48, W, yy + 48, p.hairline))
        yy += 52
    out.append(s)

    # Memory ---------------------------------------------------------------
    s = Screen("memory", "Memory", "Scope filter, per-entry forget", palette=p)
    s.header("Memory", actions=["dots"])
    x = 16
    for label, sel in [("All", True), ("Global", False), ("Project", False)]:
        x = s.chip(x, 72, label, selected=sel)
    yy = s.section(124, "Global")
    for fact in [
        "Prefers Dart and Flutter",
        "Works in IST, replies in Hinglish",
        "Ships to Play internal testing",
    ]:
        s.parts.append(text(16, yy + 20, fact, 13, p.text))
        s.parts.append(icon("trash", W - 40, yy + 6, 18, p.faint))
        s.parts.append(line(16, yy + 32, W, yy + 32, p.hairline))
        yy += 40
    yy = s.section(yy + 12, "Project · Ovid Si")
    s.parts.append(text(16, yy + 20, "Repo is aasheesh/ovid-app", 13, p.text))
    s.parts.append(icon("trash", W - 40, yy + 6, 18, p.faint))
    out.append(s)

    # Memory files ---------------------------------------------------------
    s = Screen("memory_files", "Memory files", "The .md files, view and edit", palette=p)
    s.header("Memory files")
    x = 16
    for label, sel in [("All", True), ("Global", False), ("Project", False)]:
        x = s.chip(x, 72, label, selected=sel)
    yy = 124
    for name, meta in [
        ("global.md", "Global · 2 KB"), ("ovid-si.md", "Project · 4 KB"),
        ("session-408.md", "Chat · 1 KB"), ("session-412.md", "Chat · 1 KB"),
    ]:
        s.parts.append(icon("file", 16, yy + 6, 20, p.muted))
        s.parts.append(text(44, yy + 18, name, 13.5, p.text))
        s.parts.append(text(44, yy + 36, meta, 11, p.faint))
        s.parts.append(icon("chevron", W - 40, yy + 12, 18, p.faint))
        s.parts.append(line(16, yy + 48, W, yy + 48, p.hairline))
        yy += 54
    s.button(16, H - 88, W - 32, "Export all", primary=False)
    out.append(s)

    # Data control ---------------------------------------------------------
    s = Screen("data_control", "Data control", "Four rows, honest limits", palette=p)
    s.header("Data control")
    yy = 84
    for label, meta, ic in [
        ("Export backup", "Up to 64 MB", "share"),
        ("Import backup", "Your plan storage", "file"),
        ("Clear cache", "170 MB", "trash"),
        ("Delete data", "Chats, artifacts, memory", "trash"),
    ]:
        danger = label.startswith("Delete")
        s.parts.append(icon(ic, 16, yy + 14, 20, p.agent if danger else p.muted))
        s.parts.append(text(52, yy + 24, label, 14, p.agent if danger else p.text))
        s.parts.append(text(52, yy + 42, meta, 11, p.faint))
        s.parts.append(icon("chevron", W - 40, yy + 16, 18, p.faint))
        s.parts.append(line(16, yy + 56, W, yy + 56, p.hairline))
        yy += 62
    out.append(s)

    # Storage --------------------------------------------------------------
    s = Screen("storage", "Storage", "One bar, legend, clear cache", palette=p)
    s.header("Storage")
    s.parts.append(text(16, 96, "4.2 GB of 15 GB", 20, p.text, weight=600))
    s.parts.append(text(16, 118, "28 % used", 12, p.faint))
    segs = [("Chats", 0.34, 1.0), ("Artifacts", 0.28, 0.72), ("Memory", 0.06, 0.45)]
    bx = 16
    for _, frac, alpha in segs:
        w = (W - 32) * frac
        s.parts.append(rect(bx, 140, w - 2, 12, p.text, rx=3, opacity=alpha))
        bx += w
    s.parts.append(rect(16, 140, W - 32, 12, "none", rx=3, stroke=p.hairline))
    yy = 176
    for label, frac, alpha in segs:
        s.parts.append(rect(16, yy + 4, 10, 10, p.text, rx=2, opacity=alpha))
        s.parts.append(text(34, yy + 13, label, 12.5, p.text))
        s.parts.append(text(W - 16, yy + 13, f"{int(frac * 100)} %", 12, p.faint, anchor="end"))
        yy += 26
    s.parts.append(line(16, yy + 16, W, yy + 16, p.hairline))
    s.parts.append(text(16, yy + 44, "Clear cache", 14, p.text))
    s.parts.append(text(W - 16, yy + 44, "170 MB", 12.5, p.faint, anchor="end"))
    out.append(s)

    # Appearance -----------------------------------------------------------
    s = Screen("appearance", "Appearance", "Theme tiles, text size, voice", palette=p)
    s.header("Appearance")
    yy = s.section(84, "Theme")
    tw = (W - 44) / 3
    for i, (label, sel) in enumerate([("System", True), ("Light", False), ("Dark", False)]):
        tx = 16 + i * (tw + 6)
        s.parts.append(
            rect(tx, yy, tw, 78, p.surface, rx=10,
                 stroke=p.text if sel else p.hairline, stroke_width=1.5)
        )
        s.parts.append(rect(tx + 10, yy + 10, tw - 20, 8, p.surface_alt, rx=3))
        s.parts.append(rect(tx + 10, yy + 24, tw - 34, 6, p.surface_alt, rx=3))
        s.parts.append(rect(tx + 10, yy + 36, tw - 24, 6, p.surface_alt, rx=3))
        s.parts.append(text(tx + tw / 2, yy + 66, label, 10.5, p.text, anchor="middle"))
    yy = s.section(yy + 96, "Text size")
    s.parts.append(rect(16, yy + 12, W - 32, 4, p.hairline, rx=2))
    s.parts.append(circle(16 + (W - 32) * 0.45, yy + 14, 9, p.text))
    s.parts.append(text(16, yy + 40, "A", 11, p.faint))
    s.parts.append(text(W - 16, yy + 40, "A", 17, p.faint, anchor="end"))
    yy += 60
    s.parts.append(text(16, yy + 20, "Voice language", 14, p.text))
    s.parts.append(text(W - 16, yy + 20, "English", 12.5, p.faint, anchor="end"))
    out.append(s)

    # Credentials ----------------------------------------------------------
    s = Screen("credentials", "Credentials", "Masked keys, add and remove", palette=p)
    s.header("Credentials", actions=["plus"])
    yy = 84
    for name, meta in [
        ("GitHub PAT", "•••• 4f2a"),
        ("Personal token", "•••• 91bc"),
        ("Browser login", "2 saved"),
    ]:
        s.parts.append(icon("key", 16, yy + 14, 20, p.muted))
        s.parts.append(text(52, yy + 24, name, 14, p.text))
        s.parts.append(text(52, yy + 42, meta, 11, p.faint))
        s.parts.append(icon("dots", W - 42, yy + 16, 20, p.muted))
        s.parts.append(line(16, yy + 56, W, yy + 56, p.hairline))
        yy += 62
    s.parts.append(text(W / 2, H - 60, "Revoke all", 13, p.agent, anchor="middle"))
    out.append(s)

    # Account health -------------------------------------------------------
    s = Screen("account_health", "Account health", "One status line, short list", palette=p)
    s.header("Account health")
    s.card(16, 80, W - 32, 84)
    s.parts.append(text(32, 112, "Healthy", 19, p.text, weight=600))
    s.parts.append(text(32, 134, "No issues found in the last check.", 12, p.muted))
    yy = 184
    for k, v in [
        ("Plan", "Ovid Plus · active"),
        ("Usage", "18.4M of 50M today"),
        ("Storage", "4.2 GB of 15 GB"),
        ("Deletion", "Not requested"),
    ]:
        s.parts.append(text(16, yy, k, 12, p.faint))
        s.parts.append(text(W - 16, yy, v, 12.5, p.text, anchor="end"))
        s.parts.append(line(16, yy + 14, W, yy + 14, p.hairline))
        yy += 34
    out.append(s)

    # About ----------------------------------------------------------------
    s = Screen("about", "About", "Version, three legal links", palette=p)
    s.header("About")
    s.agent_mark(W / 2, 140, 28)
    s.parts.append(text(W / 2, 196, "Ovid Si", 20, p.text, anchor="middle", weight=600))
    s.parts.append(text(W / 2, 218, "1.0.0 (3)", 12, p.faint, anchor="middle"))
    yy = 260
    for label in ["Privacy policy", "Terms of service", "Open-source licences"]:
        s.parts.append(text(16, yy + 20, label, 14, p.text))
        s.parts.append(icon("chevron", W - 40, yy + 8, 18, p.faint))
        s.parts.append(line(16, yy + 36, W, yy + 36, p.hairline))
        yy += 44
    out.append(s)

    # Notifications --------------------------------------------------------
    s = Screen("notifications", "Notifications", "Master, channels, quiet hours", palette=p)
    s.header("Notifications")
    yy = 84
    s.parts.append(text(16, yy + 20, "Push notifications", 14, p.text, weight=600))
    s.parts.append(rect(W - 56, yy + 10, 40, 22, p.text, rx=11))
    s.parts.append(circle(W - 27, yy + 21, 9, p.bg))
    yy = s.section(yy + 52, "Channels")
    for label, on in [("Runs finished", True), ("Schedules", True), ("New sign-ins", False)]:
        s.parts.append(text(16, yy + 22, label, 13.5, p.text))
        s.parts.append(rect(W - 56, yy + 10, 40, 22, p.text if on else p.surface_alt, rx=11))
        s.parts.append(circle(W - 27 if on else W - 45, yy + 21, 9, p.bg if on else p.muted))
        yy += 44
    yy += 8
    s.parts.append(text(16, yy + 20, "Quiet hours", 14, p.text))
    s.parts.append(text(W - 16, yy + 20, "22:00 – 06:00", 12.5, p.faint, anchor="end"))
    yy += 40
    s.parts.append(text(16, yy + 20, "Sound", 14, p.text))
    s.parts.append(text(W - 16, yy + 20, "Ovid chime", 12.5, p.faint, anchor="end"))
    out.append(s)

    # Presets --------------------------------------------------------------
    s = Screen("presets", "Agent presets", "List, apply, create, delete", palette=p)
    s.header("Agent presets", actions=["plus"])
    yy = 84
    for name, meta, sel in [
        ("Fast", "Short answers · Flash", True),
        ("Deep", "Reasons before acting · Pro", False),
        ("Code review", "Checks every diff", False),
    ]:
        s.parts.append(text(16, yy + 22, name, 14, p.text, weight=500))
        s.parts.append(text(16, yy + 40, meta, 11.5, p.faint))
        if sel:
            s.parts.append(icon("check", W - 44, yy + 16, 20, p.text))
        else:
            s.parts.append(icon("dots", W - 42, yy + 14, 20, p.muted))
        s.parts.append(line(16, yy + 54, W, yy + 54, p.hairline))
        yy += 60
    out.append(s)

    # Response wait --------------------------------------------------------
    s = Screen("response_wait", "Response wait", "Slider and three presets", palette=p)
    s.header("Response wait")
    s.parts.append(text(16, 128, "2 min", 30, p.text, weight=600))
    s.parts.append(text(16, 152, "then it reports back", 12, p.faint))
    s.parts.append(rect(16, 190, W - 32, 4, p.hairline, rx=2))
    s.parts.append(circle(16 + (W - 32) * 0.32, 192, 10, p.text))
    x = 16
    for label, sel in [("1 min", False), ("2 min", True), ("5 min", False)]:
        x = s.chip(x, 226, label, selected=sel)
    out.append(s)

    # Permissions ----------------------------------------------------------
    s = Screen("permissions", "Permissions", "Five rows, status and action", palette=p)
    s.header("Permissions", actions=["clock"])
    yy = 84
    for name, status, ok in [
        ("Camera", "Granted", True), ("Microphone", "Granted", True),
        ("Photos", "Not asked", False), ("Notifications", "Blocked", False),
        ("Storage", "Granted", True),
    ]:
        s.parts.append(text(16, yy + 22, name, 14, p.text))
        s.parts.append(rect(W - 108, yy + 8, 92, 24, p.surface_alt, rx=12))
        s.parts.append(
            text(W - 62, yy + 24, status, 10.5, p.text if ok else p.muted, anchor="middle")
        )
        s.parts.append(line(16, yy + 42, W, yy + 42, p.hairline))
        yy += 48
    out.append(s)

    return out
