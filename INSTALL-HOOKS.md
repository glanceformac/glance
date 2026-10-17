# Claude Code hooks for Glance

Nothing here has been installed. Glance never edits your Claude Code settings. To turn the
integration on, add the JSON below to `~/.claude/settings.json` yourself (or ask Claude to,
once you have reviewed it). If the file already has a `"hooks"` key, merge these seven
events into it instead of adding a second `"hooks"` key.

The format follows the current hooks reference: https://code.claude.com/docs/en/hooks

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/Glance.app/Contents/MacOS/glance-hook",
            "timeout": 75
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/Glance.app/Contents/MacOS/glance-hook",
            "timeout": 10
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/Glance.app/Contents/MacOS/glance-hook",
            "timeout": 10
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/Glance.app/Contents/MacOS/glance-hook",
            "timeout": 10
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/Glance.app/Contents/MacOS/glance-hook",
            "timeout": 10
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/Glance.app/Contents/MacOS/glance-hook",
            "timeout": 10
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/Glance.app/Contents/MacOS/glance-hook",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

These paths point at the installed copy in /Applications (from the installer, Homebrew or `./build.sh install`). If you installed Glance somewhere else, update the `command` paths.

## What each hook does

| Event | What Glance shows | Required? |
|---|---|---|
| `PermissionRequest` | "Claude needs your OK" card: the full command or tool input (scrollable, never cut off), the project folder name, Allow (⌃⌥Y) and Deny (⌃⌥N) | Main feature |
| `Stop` | Green "Done" peek with the project name and how long the turn took | Recommended |
| `UserPromptSubmit` | Nothing visible. It only records the start time so the Done peek can show a duration | Optional (without it, Done shows no duration) |
| `Notification` (`idle_prompt`) | A short peek when Claude is waiting for your input | Optional |
| `PostToolUse` (Bash, Edit, Write…) | Counts files changed (shown in the Done animation). A successful `git commit` plays the passing-move COMMIT animation; `git push`, `vercel` / `vercel deploy` and `gh pr create` play the floodlight PUSHED / DEPLOYED / PR OPENED animation | Optional (football celebrations) |
| `PostToolUseFailure` (Bash) | If one of those commands fails: the red-card animation with the first line of the error | Optional |
| `PreToolUse` (Bash) | Long-command islands: when a Bash call runs longer than the threshold (Settings › Developer, default 30 s), a small running capsule with the command and a clock appears inside the pill; when it ends (`PostToolUse` / `PostToolUseFailure`) a peek shows how long it took and its exit status | Optional |

For these events the helper strips file contents and tool output before sending; only the
command line, file path and the first 800 characters of an error reach Glance. For a Bash
`PostToolUse` it also passes one flag, whether the call was interrupted (no output text).

`PreToolUse` never blocks or changes anything: the helper sends the event and exits at once with
no output (so Claude Code's own permission rules decide as usual). For tools other than Bash it
exits without even connecting. While a permission card for that command is waiting, the clock
does not run; if you deny it, the capsule is removed. A turn ending (`Stop`) clears anything left.

`GLANCE_SOCKET_PATH` (test only): if set, the helper talks to that socket instead (same ownership
checks), so an isolated test instance can be driven without touching the real one.

## Safety behaviour (glance-hook)

- It never allows anything on its own. An allow decision is only returned after you click
  Allow or press ⌃⌥Y in Glance.
- Deny returns a proper decision:
  `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied by the user from Glance."}}}`
- Allow returns `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
  with no `updatedInput` and no `updatedPermissions`, so the command is never changed and no
  "always allow" rules are added. Your deny/ask rules in settings still apply.
- In each of these cases the helper exits 0 with no output, so Claude Code shows its normal
  terminal prompt (no decision means ask in the terminal):
  - Glance is not running, or the socket is missing (tested: exits in ~20 ms)
  - the socket is not a real socket owned by your user (symlink protection)
  - you don't answer within 56 s (Glance gives up) or 58 s (helper deadline)
  - Glance quits or crashes while the card is showing
  - the reply is malformed
- Communication is only over a Unix socket at
  `~/Library/Application Support/Glance/glance.sock` (folder 0700, socket 0600). Glance
  also checks the connecting process belongs to your user (`getpeereid`). No network port is
  ever opened.
- The `timeout` of 75 s is longer than the helper's own 58 s deadline, so Claude Code never
  has to kill it.

## Testing it without Claude Code

```sh
H=/Applications/Glance.app/Contents/MacOS/glance-hook
echo '{"hook_event_name":"PermissionRequest","cwd":"'"$PWD"'","tool_name":"Bash","tool_input":{"command":"echo hello"}}' | $H
# Glance shows the card; click Allow or Deny and the JSON decision prints here.
```

Long-command test (needs the `PreToolUse` hook):

```sh
H=/Applications/Glance.app/Contents/MacOS/glance-hook
echo '{"hook_event_name":"PreToolUse","session_id":"t","cwd":"'"$PWD"'","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"sleep 40"}}' | $H
sleep 35   # the capsule appears in the pill after 30 s
echo '{"hook_event_name":"PostToolUse","session_id":"t","cwd":"'"$PWD"'","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"sleep 40"}}' | $H
# A "sleep 40 · 35s · exit 0" peek shows.
```
