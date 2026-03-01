# Wireframe / Full-UI-Tree Issues Log

## Issue 1: Wireframe shows generic `label` instead of `description` for buttons

**Window**: 欢迎使用 Outlook (Welcome) — window ID 8390
**Date**: 2026-02-28

### Problem

The wireframe renders `[elem_28|按钮]` and `[elem_29|按钮]` — using the generic AX `label` ("按钮" = "button") rather than the `description` field which contains the actual button text.

### Comparison

| elem_id | label (shown in wireframe) | description (from --json-output) |
|---------|---------------------------|----------------------------------|
| elem_28 | 按钮 | 稍后完成 (Finish Later) |
| elem_29 | 按钮 | 继续 (Continue) |
| elem_4  | 按钮 | 外观浅色 |
| elem_6  | 按钮 | 外观深色 |
| elem_8  | 按钮 | 外观系统, 已选则 |
| elem_11 | 按钮 | 默认主题蓝色, 已选则 |
| elem_27 | 按钮 | 有关荣耀时刻主题的详细信息 |

All 20+ buttons in this window have `label: "按钮"` and meaningful text only in `description`.

### Impact

- Agent cannot distinguish buttons from wireframe alone
- Must fall back to `--json-output` to identify which button does what
- Wireframe is effectively useless for this window because every interactive element shows the same label

### Suggested improvement

Wireframe rendering should prefer `description` over `label` when `label` is generic/unhelpful (e.g., equals the role_description like "按钮"/"button"), or show both: `[elem_29|继续]` instead of `[elem_29|按钮]`.

### Raw data

Full UI tree JSON saved at: `~/.peekaboo/snapshots/D93BCEF7-CEF6-4F4B-951E-7B87E4D233E3/`

## Issue 2: Element detection times out on closed/empty windows instead of returning quickly

**Window**: 欢迎使用 Outlook (Welcome) — window ID 8390 (after wizard completed)
**Date**: 2026-02-28

### Problem

After clicking "完成" (Done) to close the welcome wizard, the window disappeared visually but remained in `list windows` output briefly. Running `peekaboo see --window-id 8390 --json-output` on this zombie window:
- Window capture succeeded (133ms) — screenshot was taken
- Element detection then waited the full 20-second timeout before failing

### Error message

```
Error: Element detection timed out after 20s. Try narrowing the capture, targeting a specific window, or increasing the timeout.
```

### Root cause

peekaboo doesn't distinguish between "window exists but has no AX elements" (closed/empty window) and "elements are still loading" (slow app). For a window with zero elements, it should return an empty result immediately rather than waiting 20 seconds.

### Suggested improvement

If the initial AX traversal returns zero elements and the window has no AX children, return an empty result after a short grace period (e.g., 2 seconds) rather than waiting the full timeout.

## Issue 3: Wireframe doesn't show email content — "other" role elements lose `description` text

**Window**: 收件箱 • ronleonearth@hotmail.com (Inbox) — window ID 8386
**Date**: 2026-02-28

### Problem

The email message list in Outlook's inbox uses role `AXOther` (mapped to "other") for both table rows ("表格行") and cells ("单元格"). The wireframe renders these as bare element IDs without any content:

```
│[elem_107]          █│
│[elem_109]          █│
│[elem_112]          █│
│[elem_115]          █│
```

The critical information — sender, subject, read/unread status — is only in the `description` field:

| elem_id | role | label (wireframe) | description (--json-output only) |
|---------|------|-------------------|----------------------------------|
| elem_105 | other | 表格 | 邮件列表 |
| elem_107 | other | 单元格 | 其他电子邮件 来自 招商银行信用卡, Ben Thompson, The Washington Po... |
| elem_112 | other | 单元格 | 未读， 发送者: GitHub, 主题: [GitHub] Claude is reque... |
| elem_115 | other | 单元格 | 1 封未读邮件， 对话， 2 邮件， 发送者: Michał Pierzchała, 主题: ... |
| elem_120 | other | 单元格 | 未读， 发送者: zcgl@cmschina.com.cn, 主题: 招商证券资产管理有限... |
| elem_123 | other | 单元格 | 发送者: 富途證券(香港), 主题: 保證金綜合帳戶(6070)... |

### Impact

- **Wireframe alone cannot identify emails**: Agent sees a column of identical `[elem_NNN]` entries with no way to tell which email is which
- **Must use `--json-output`** to find a specific email to click — doubles the peekaboo calls needed
- **Automated testing workflow broken**: The SKILL.md recommends "wireframe for text verification" but this window requires json-output for any meaningful identification

### Root cause

Same as Issue 1: wireframe rendering uses `label` field, but Outlook's web-based UI stores all meaningful text in `description`. For "other" role elements, `label` is always the generic "单元格" (cell) or "表格行" (table row).

### Suggested improvement

1. **Primary**: When rendering wireframe labels, use a fallback chain: `label` → `description` → `value` → element ID only
2. **Alternative**: For elements with role "other" and a generic label (单元格/表格行/组), always show `description` truncated to ~40 chars
3. **Ideal**: Show `[elem_112|GitHub: [GitHub] Claude is...]` instead of `[elem_112]`

### Note

This issue + Issue 1 share the same root cause and could be fixed together. The pattern is:
- **Buttons**: `label` = "按钮" (generic), `description` = actual button text
- **Table cells**: `label` = "单元格" (generic), `description` = actual cell content
- **Groups**: `label` = "组" (generic), `description` = actual group purpose

## Issue 4: `press escape` without `--app` sends keystroke to terminal, not target app

**Context**: Dismissing Outlook print dialog during Step 2
**Date**: 2026-02-28

### Problem

Running `peekaboo press escape` without `--app` sent the Escape key to the currently focused application — the terminal running Claude Code CLI — instead of to Microsoft Outlook's print dialog. This terminated the Claude Code session.

### Root cause

`peekaboo press` delivers keystrokes to the frontmost/focused application. When Claude Code is running in a terminal, the terminal is the focused app, not Outlook. Without `--app` to specify the target, the keystroke goes to the wrong place.

### Correct pattern

```bash
# ALWAYS specify --app for press/hotkey commands
peekaboo press escape --app "Microsoft Outlook"

# NEVER use bare press without --app
# peekaboo press escape  # ← WRONG: goes to terminal
```

### Note on --app pitfall conflict

This conflicts with the earlier finding that `--app` causes bridge errors on non-main windows for `click`. The rules are:
- **`click --on`**: Omit `--app` (bridge error on secondary windows)
- **`press`/`hotkey`**: Always include `--app` (otherwise keystroke goes to wrong app)
- **`see`**: Use `--app` for main window, `--window-title` for secondary windows

## Issue 5: `press`/`hotkey` with `--app` on system sheet dialogs takes 180+ seconds

**Context**: Dismissing macOS Print dialog (system sheet) from Outlook
**Date**: 2026-02-28

### Problem

| Command | Result | Duration |
|---------|--------|----------|
| `peekaboo press escape` (no --app) | Sent to terminal, killed Claude Code | instant |
| `peekaboo press escape --app "Microsoft Outlook"` | Timed out / hung | >10min (killed manually) |
| `peekaboo press escape --window-id 8663` | No output, no effect | unknown |
| `peekaboo hotkey "escape" --app "Microsoft Outlook"` | **Succeeded** | **182 seconds** |

The `hotkey` command eventually worked but took 3 minutes for a single Escape keystroke.

### Analysis

- The print dialog (window ID 8663) was a **macOS system sheet** — a modal panel attached to the main window, rendered by the system printing framework, not by the Outlook app
- `press --window-id` appears unsupported or non-functional (no output produced)
- `press --app` hung indefinitely (likely same AX bridge delay but without eventual success)
- `hotkey --app` succeeded after 182s — the AX system eventually resolved the target but with extreme latency

### Root cause hypothesis

System sheets are owned by the app's process but their AX tree is managed by macOS system frameworks. When peekaboo resolves `--app "Microsoft Outlook"`, it may be attempting to traverse the full AX tree (including the sheet) looking for the correct target, hitting timeouts on sheet elements that don't respond normally to AX queries.

### Practical workaround

For system sheets (Print, Save, Open dialogs), the safest approach is:
1. Use `peekaboo window focus --app "Microsoft Outlook"` to bring Outlook to front
2. Then use `osascript -e 'tell application "System Events" to keystroke "." using command down'` or similar AppleScript for Cmd+. (cancel)
3. Or use coordinate-based `peekaboo click --x --y` on the Cancel button

## Issue 6: System sheet (Print dialog) blocks ALL AX tree access for the entire app

**Context**: Step 8 — Print dialog opened via 文件 > 打印...
**Date**: 2026-02-28

### Problem

When the macOS system Print dialog (sheet) is visible, **all** `peekaboo see` commands fail with element detection timeout — not just for the sheet window itself, but for the entire app:

| Command | Result |
|---------|--------|
| `peekaboo see --window-id 8780` (print sheet) | Element detection timed out after 20s |
| `peekaboo see --app "Microsoft Outlook"` (main window) | Element detection timed out after 20s |

This is worse than Issue 5 (where `hotkey` eventually worked after 182s). The system sheet appears to **lock the app's entire AX hierarchy**, preventing any element traversal.

### Comparison with first round

In the first round of testing, `peekaboo see --app` could read the print dialog's AX tree (buttons, labels were visible). The difference is unclear — possibly:
- peekaboo version change between rounds
- Different dialog state (expanded vs collapsed print options)
- AX system caching from prior traversals

### Impact

- Cannot verify print dialog appeared (no element data)
- Cannot find Cancel/Print button element IDs
- Cannot even read the main inbox window while dialog is open
- Only option is coordinate-based clicking or AppleScript

### Required investigation (peekaboo code level)

1. Why does a system sheet block the entire app's AX tree traversal?
2. Is the element detection loop waiting for a response that will never come?
3. Can peekaboo detect the "sheet present" state and handle it differently?
4. Should there be a fast-fail path when AX traversal gets no response within ~2s?
