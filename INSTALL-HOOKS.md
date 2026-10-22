# Claude Code hooks for Glance

Glance never edits your Claude Code settings. You connect it by adding a few hook entries to
`~/.claude/settings.json` yourself. It takes about two minutes, and you can remove them any time.

What you get: the "Claude needs your OK" approval card (Allow / Deny from the island or the
Touch Bar), the Done peek, the notch character reacting to Claude, and Shadow Clones for
Claude's helper agents.

## Set it up

1. Make a copy of your settings first:
   `cp ~/.claude/settings.json ~/.claude/settings.json.before-glance`
   (If the file does not exist yet, create it with `{}` in it.)
2. Open `~/.claude/settings.json` in a text editor.
3. If the file has **no** `"hooks"` key: add the `"hooks"` block below as a new top-level key
   (mind the comma after the previous key).
   If it **already has** a `"hooks"` key: for each event below, add Glance's entry to that
   event's list next to your own entries, or add the event if it is not there. Do not add a
   second `"hooks"` key, and do not change your existing entries.
4. Check the file is still valid JSON:
   `python3 -m json.tool ~/.claude/settings.json > /dev/null && echo OK`
5. Restart any running Claude Code sessions so they load the hooks.

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
    ],
    "SubagentStart": [
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
    "SubagentStop": [
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
    "StopFailure": [
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
    "SessionEnd": [
      {
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
| `SubagentStart` / `SubagentStop` | Shadow clones: while Claude Code runs subagents, the notch character gets one clone per running subagent, labelled with its agent type ("Explore", "Plan", or "Helper"). In the open island the clones stand beside the character (up to four, then "+N"); the closed pill shows a small face per clone and the count; on the Touch Bar they run along the strip. A clone pops in when its subagent starts, waves with an orange glow while that subagent waits for your approval, hops when it is done and then leaves in a puff of its pack's effect (smoke, fox-fire or rice flour). Turn it off in Settings › Character | Optional (needs the character) |
| `StopFailure`, `SessionEnd` | Nothing visible. They end the "working" state and clear any clones when a turn fails or a session closes | Optional |
| `PreToolUse` (Bash) | Long-command islands: when a Bash call runs longer than the threshold (Settings › Developer, default 30 s), a small running capsule with the command and a clock appears inside the pill; when it ends (`PostToolUse` / `PostToolUseFailure`) a peek shows how long it took and its exit status | Optional |

For these events the helper strips file contents and tool output before sending; only the
command line, file path and the first 800 characters of an error reach Glance. For a Bash
`PostToolUse` it also passes one flag, whether the call was interrupted (no output text).

Shadow clones are matched by `agent_id`; their label comes from `agent_type`. A
`PermissionRequest` that carries an `agent_id` (one asked from inside a subagent) makes that
subagent's clone wave and names it on the approval card. A main-session `Stop` clears the session's clones,
except for background subagents still listed as running in its `background_tasks`; the idle
prompt notification, `StopFailure` and `SessionEnd` clear them too. A clone whose subagent has
sent nothing for 20 minutes is removed, in case its stop event was missed. For `Stop` and
`SubagentStop` the helper passes only the type and status of each background task (no
descriptions, commands or scheduled prompts) and drops the subagent's final message.

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

## Check it works

With Glance running, paste this in a terminal. The approval card should appear in the island;
click Allow or Deny and the decision prints in the terminal.

```sh
H=/Applications/Glance.app/Contents/MacOS/glance-hook
echo '{"hook_event_name":"PermissionRequest","cwd":"'"$PWD"'","tool_name":"Bash","tool_input":{"command":"echo hello"}}' | $H
```

Then, in Claude Code, ask for something that needs permission (for example a shell command):
the same card appears. Ask Claude to use a helper agent and a small clone shows beside the
character while it works.

## Remove it

Delete every entry whose `"command"` ends in `glance-hook` from `~/.claude/settings.json`,
and any event list that is left empty. Or put your copy back:
`cp ~/.claude/settings.json.before-glance ~/.claude/settings.json`. Restart Claude Code sessions.
If Glance is not running, the hooks do nothing and Claude Code asks in the terminal as usual.

## More tests without Claude Code

Long-command test (needs the `PreToolUse` hook):

```sh
H=/Applications/Glance.app/Contents/MacOS/glance-hook
echo '{"hook_event_name":"PreToolUse","session_id":"t","cwd":"'"$PWD"'","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"sleep 40"}}' | $H
sleep 35   # the capsule appears in the pill after 30 s
echo '{"hook_event_name":"PostToolUse","session_id":"t","cwd":"'"$PWD"'","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"sleep 40"}}' | $H
# A "sleep 40 · 35s · exit 0" peek shows.
```
