---
description: Configure environment variables for the agentic-framework-mcp servers (Context7 API key, filesystem root)
argument-hint: (no arguments)
---

# /agentic-framework-mcp:setup — Configure MCP Environment

## Overview

This command configures environment variables for the agentic-framework MCP servers:
- **CONTEXT7_API_KEY** — API key for the context7 documentation server (optional; keyless operation is supported)
- **MCP_FS_ROOT** — filesystem server root directory (optional; defaults to project directory)

**Important:** This command is part of the agentic-framework-mcp plugin and works standalone, without requiring the core agentic-framework plugin. Execute all shell commands directly in your own terminal using your Bash or PowerShell tooling — do not delegate to agents.

---

## Flow

### Step 1: Detect platform and check existing CONTEXT7_API_KEY

**On Windows (PowerShell):**

Run these commands in PowerShell (or CMD for checking only):

```powershell
# Check process environment
$env:CONTEXT7_API_KEY

# Check user-scope registry (survives terminal restarts)
[Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY','User')
```

**On macOS/Linux:**

```bash
# Check environment variable
printenv CONTEXT7_API_KEY

# Or check your shell profile (~/.zshrc, ~/.bashrc, etc.)
grep CONTEXT7_API_KEY ~/.zshrc 2>/dev/null || grep CONTEXT7_API_KEY ~/.bashrc 2>/dev/null
```

If either returns a value: **proceed to Step 7 (MCP_FS_ROOT)**. Report: "CONTEXT7_API_KEY is set (c7..., 4 leading chars masked)". The variable is already configured.

If neither returns a value: proceed to Step 2.

---

### Step 2: Present three options for CONTEXT7_API_KEY setup

Ask the user which option they prefer:

**Option A: Keyless (default, skip setup)**
> The context7 server works without an API key at lower rate limits. A key can be added later by re-running this command. Proceed to Step 7 (MCP_FS_ROOT).

**Option B: Manual setup (privacy-preserving, recommended)**
> The assistant will print one-liner commands for you to run in your own terminal, so the token never enters this conversation. The setup persists to your system and survives terminal restarts. Proceed to Step 3 (Option B).

**Option C: Provide it now (transcript-aware)**
> You provide the token to this conversation. **WARNING:** The token will pass through this conversation and be stored in the session transcript. Option B avoids this by having you enter the token in your own terminal instead. If you choose this option anyway, proceed to Step 4 (Option C).

---

### Step 3: Handle option B — print interactive snippet (recommended approach)

**Only if the user chooses Option B:**

Display this instruction and copy-paste the appropriate snippet into YOUR OWN TERMINAL — do not run it here:

**On Windows (PowerShell):** — EXAMPLE code snippet

```powershell
# EXAMPLE: Copy and paste this into YOUR OWN PowerShell terminal:
$secureToken = Read-Host -Prompt 'Paste your Context7 API key' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemAlloc($secureToken)
try {
  $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
  if ($plainToken -notmatch '^[A-Za-z0-9_-]+$') {
    Write-Host "ERROR: API key contains invalid characters. Must match ^[A-Za-z0-9_-]+`$" -ForegroundColor Red
  } else {
    [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $plainToken, 'User')
    Write-Host "Verified: CONTEXT7_API_KEY set (c7..., 4 leading chars masked)"
  }
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($ptr)
  Remove-Variable -Name plainToken, secureToken -ErrorAction SilentlyContinue
}
```

**On macOS/Linux (bash):** — EXAMPLE code snippet

```bash
# EXAMPLE: Copy and paste this into YOUR OWN terminal:
# EXAMPLE: Secure token capture and persistence (works on bash, zsh, and ksh; read -s is a shell extension, not POSIX — dash/ash don't support it)
printf 'Paste your Context7 API key: '
read -r -s C7KEY
printf '\n'
if ! printf '%s\n' "$C7KEY" | grep -E '^[A-Za-z0-9_-]+$' > /dev/null; then
  echo "ERROR: API key contains invalid characters. Must match ^[A-Za-z0-9_-]+ without spaces or special chars" >&2
else
  SHELL_NAME=$(basename "$SHELL")
  case "$SHELL_NAME" in
    zsh)
      grep -q "^export CONTEXT7_API_KEY=" ~/.zshrc || printf 'export CONTEXT7_API_KEY="%s"\n' "$C7KEY" >> ~/.zshrc  # EXAMPLE: setup
      echo "Added to ~/.zshrc"
      ;;
    bash)
      grep -q "^export CONTEXT7_API_KEY=" ~/.bashrc || printf 'export CONTEXT7_API_KEY="%s"\n' "$C7KEY" >> ~/.bashrc  # EXAMPLE: setup
      grep -q "^export CONTEXT7_API_KEY=" ~/.bash_profile || printf 'export CONTEXT7_API_KEY="%s"\n' "$C7KEY" >> ~/.bash_profile  # EXAMPLE: setup
      echo "Added to ~/.bashrc and ~/.bash_profile"
      ;;
    *)
      echo "ERROR: Unknown shell: $SHELL_NAME" >&2
      echo "Manually add to your shell profile: export CONTEXT7_API_KEY=\"$C7KEY\"" >&2
      ;;
  esac
fi
# Clear the variable from memory
unset C7KEY
```

**On macOS/Linux (fish):** — EXAMPLE code snippet

```fish
# EXAMPLE: Copy and paste this into YOUR OWN fish terminal:
# EXAMPLE: Secure token capture and persistence
set -l c7key (read -s -P 'Paste your Context7 API key: ')
if printf '%s\n' "$c7key" | grep -E '^[A-Za-z0-9_-]+$' > /dev/null 2>&1
  if not set -q CONTEXT7_API_KEY; set -Ux CONTEXT7_API_KEY "$c7key"; end  # EXAMPLE: setup
  echo "Added to fish configuration"
else
  echo "ERROR: API key contains invalid characters. Must match ^[A-Za-z0-9_-]+ without spaces or special chars" >&2
end
set -e c7key
```

**After you run the snippet in your own terminal:**

- **On Windows:** Proceed directly to Step 5 (Verify the persisted value).
- **On macOS/Linux:** Open a new terminal tab and proceed to Step 5. Your current shell won't see the variable until re-sourced.

---

### Step 4: Handle option C — capture and persist the token

**Only if the user chooses Option C:**

Display this warning verbatim:

> **⚠ SECURITY WARNING ⚠**
>
> The token you provide will:
> - Pass through this conversation
> - Be stored in the session transcript
> - Be visible in tool-command logs and process listings during persistence
> - Be visible to anyone with access to this conversation history
>
> **STRONGLY RECOMMENDED:** Choose Option B instead — it avoids putting your token in a transcript. The one-liner is designed to be run once in your own terminal, keeping the token off the internet.
>
> If you understand and still wish to proceed, provide your Context7 API key.

If the user provides the token:

1. **Validate the token format** — token must match `^[A-Za-z0-9_-]+$` (letters, digits, underscore, hyphen only). If validation fails:
   - Print: `ERROR: API key contains invalid characters. Must match ^[A-Za-z0-9_-]+$ without spaces or special chars.`
   - Do NOT persist. Stop here.

2. **Persist it to user-scope environment (Windows):** — EXAMPLE code

```powershell
# EXAMPLE: Validate and persist
# Validate first
$plainToken = Read-Host -Prompt 'Paste your Context7 API key' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemAlloc($plainToken)
try {
  $tokenValue = [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
  if ($tokenValue -notmatch '^[A-Za-z0-9_-]+$') {
    Write-Host "ERROR: API key contains invalid characters. Must match ^[A-Za-z0-9_-]+`$ without spaces or special chars." -ForegroundColor Red
  } else {
    [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $tokenValue, 'User')
    Write-Host "Verified: CONTEXT7_API_KEY set (c7..., 4 leading chars masked)"
  }
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($ptr)
  Remove-Variable -Name tokenValue, plainToken -ErrorAction SilentlyContinue
}
```

**Critical:** Use `SetEnvironmentVariable` with scope `'User'`, NOT `setx` — `setx` truncates values longer than 1024 characters.

3. **Persist it to user-scope environment (macOS/Linux):** — EXAMPLE code

Detect the user's login shell and append to its profile (with guard to prevent duplicates):

```bash
# EXAMPLE: Option C - Validate and persist token (user provides in chat)
# EXAMPLE: Secure token capture and persistence (works on bash, zsh, and ksh; read -s is a shell extension, not POSIX — dash/ash don't support it)
printf 'Paste your Context7 API key: '
read -r -s C7KEY
printf '\n'
if ! printf '%s\n' "$C7KEY" | grep -E '^[A-Za-z0-9_-]+$' > /dev/null; then
  echo "ERROR: API key contains invalid characters. Must match ^[A-Za-z0-9_-]+$ without spaces or special chars." >&2
else
  SHELL_NAME=$(basename "$SHELL")
  case "$SHELL_NAME" in
    zsh)
      grep -q "^export CONTEXT7_API_KEY=" ~/.zshrc || printf 'export CONTEXT7_API_KEY="%s"\n' "$C7KEY" >> ~/.zshrc  # EXAMPLE: setup
      echo "Added to ~/.zshrc"
      ;;
    bash)
      grep -q "^export CONTEXT7_API_KEY=" ~/.bashrc || printf 'export CONTEXT7_API_KEY="%s"\n' "$C7KEY" >> ~/.bashrc  # EXAMPLE: setup
      grep -q "^export CONTEXT7_API_KEY=" ~/.bash_profile || printf 'export CONTEXT7_API_KEY="%s"\n' "$C7KEY" >> ~/.bash_profile  # EXAMPLE: setup
      echo "Added to ~/.bashrc and ~/.bash_profile"
      ;;
    *)
      echo "ERROR: Unknown shell: $SHELL_NAME. Manually add to your shell profile:" >&2
      echo "export CONTEXT7_API_KEY=\"$C7KEY\"" >&2
      ;;
  esac
fi
unset C7KEY
```

**On macOS/Linux (fish):** — EXAMPLE code

```fish
# EXAMPLE: Option C - Validate and persist token (fish shell)
# EXAMPLE: Secure token capture and persistence
set -l c7key (read -s -P 'Paste your Context7 API key: ')
if printf '%s\n' "$c7key" | grep -E '^[A-Za-z0-9_-]+$' > /dev/null 2>&1
  if not set -q CONTEXT7_API_KEY; set -Ux CONTEXT7_API_KEY "$c7key"; end  # EXAMPLE: setup
  echo "Added to fish configuration"
else
  echo "ERROR: API key contains invalid characters. Must match ^[A-Za-z0-9_-]+ without spaces or special chars" >&2
end
set -e c7key
```

4. **SECURITY RULE:** After persisting, immediately proceed to Step 5. Never echo the token back in full — mask it to 4 leading characters only when confirming.

---

### Step 5: Verify the persisted value

**On Windows:**

```powershell
$verified = [Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY','User')
if ($verified) {
  Write-Host "Verified: CONTEXT7_API_KEY set (c7..., 4 leading chars masked)"
} else {
  Write-Host "ERROR: CONTEXT7_API_KEY not found in user scope. Check the command above."
}
```

**On macOS/Linux:**

Open a new terminal (do not use the current one — it won't see the new variable yet), then:

```bash
echo $CONTEXT7_API_KEY
# If it outputs the token (masked in reporting), verification passed.
# If it's empty, check your shell profile and re-source it: source ~/.bashrc
```

Report verification with masked output only: `set (c7..., 4 leading chars)` style.

---

### Step 6: Restart requirement

State clearly to the user:

> **A NEW TERMINAL AND A CLAUDE CODE RESTART are required before the context7 MCP server sees the new variable.** Environment variables are captured when a process starts. Close your current terminal, open a fresh one, restart Claude Code, and the setup will take effect.

---

### Step 7: MCP_FS_ROOT (filesystem server root)

**Explain the default:**

When `MCP_FS_ROOT` is unset, the filesystem MCP server roots at the current project directory (`${MCP_FS_ROOT:-${CLAUDE_PROJECT_DIR}}`). This is the safe, sensible default and works for most users.

**Offer to set a custom root:**

Ask the user: "Do you want to set a custom fixed root directory for the filesystem server, or use the default (current project directory)?"

**If yes:** Ask for the absolute path (e.g., `/home/user/documents` or `C:\Users\User\Documents`).

**Validate the path** (per platform — the danger characters differ):
- **Windows**: the value goes straight into the registry via a .NET API (no shell parsing), and backslash is the native path separator — so backslashes are ALLOWED. Forbidden: `"` `` ` `` `$` and newlines.
- **macOS/Linux/fish**: the value is written into a shell profile line that gets re-parsed at every login — forbidden: `"` `` ` `` `$` `\` (backslash) and newlines. Spaces, colons, and forward slashes are allowed.

If validation fails:
- Print: `ERROR: Path contains characters that are not allowed ( " \` $ or newlines; plus backslash on macOS/Linux ).`
- Do NOT persist. Stop here.

**If validation passes, persist:**

**On Windows (PowerShell):** — EXAMPLE code

```powershell
# EXAMPLE: Validate and persist MCP_FS_ROOT
$fsPath = Read-Host -Prompt 'Enter the absolute path for MCP_FS_ROOT (or press Enter to skip)'
if ($fsPath -and $fsPath -notmatch '["`$]' -and $fsPath -notmatch "`n") {
  [Environment]::SetEnvironmentVariable('MCP_FS_ROOT', $fsPath, 'User')
  Write-Host "Set MCP_FS_ROOT = $fsPath"
} elseif ($fsPath) {
  Write-Host "ERROR: Path contains characters that are not allowed (quote, backtick, dollar sign, or newlines)." -ForegroundColor Red
}
```

**On macOS/Linux (bash/zsh):** — EXAMPLE code

```bash
# EXAMPLE: Validate and persist MCP_FS_ROOT
read -r -p "Enter the absolute path for MCP_FS_ROOT (or press Enter to skip): " path_to_set
if [ -n "$path_to_set" ]; then
  if echo "$path_to_set" | grep -E '["`$\\]' > /dev/null 2>&1 || echo "$path_to_set" | grep -E $'\n' > /dev/null 2>&1; then
    echo "ERROR: Path contains invalid characters. Use only alphanumeric, spaces, slashes, colons, hyphens, and underscores." >&2
  else
    SHELL_NAME=$(basename "$SHELL")
    case "$SHELL_NAME" in
      zsh)
        grep -q "^export MCP_FS_ROOT=" ~/.zshrc || echo "export MCP_FS_ROOT=\"$path_to_set\"" >> ~/.zshrc
        echo "Set MCP_FS_ROOT = $path_to_set (added to ~/.zshrc)"
        ;;
      bash)
        grep -q "^export MCP_FS_ROOT=" ~/.bashrc || echo "export MCP_FS_ROOT=\"$path_to_set\"" >> ~/.bashrc
        grep -q "^export MCP_FS_ROOT=" ~/.bash_profile || echo "export MCP_FS_ROOT=\"$path_to_set\"" >> ~/.bash_profile
        echo "Set MCP_FS_ROOT = $path_to_set (added to ~/.bashrc and ~/.bash_profile)"
        ;;
      *)
        echo "ERROR: Unknown shell: $SHELL_NAME. Manually add to your shell profile:" >&2
        echo "export MCP_FS_ROOT=\"$path_to_set\"" >&2
        ;;
    esac
  fi
fi
```

**On macOS/Linux (fish):** — EXAMPLE code

```fish
# EXAMPLE: Validate and persist MCP_FS_ROOT
set -l fs_path (read -P 'Enter the absolute path for MCP_FS_ROOT (or press Enter to skip): ')
if test -n "$fs_path"
  if echo "$fs_path" | grep -E '["`$\\]' > /dev/null 2>&1
    echo "ERROR: Path contains invalid characters. Use only alphanumeric, spaces, slashes, colons, hyphens, and underscores." >&2
  else
    if not grep -q "^set -Ux MCP_FS_ROOT" ~/.config/fish/config.fish 2>/dev/null
      set -Ux MCP_FS_ROOT "$fs_path"
    end
    echo "Set MCP_FS_ROOT = $fs_path"
  end
end
set -e fs_path
```

**If no:** Confirm "MCP_FS_ROOT will default to the current project directory on each Claude Code session. You can change this anytime by re-running this command."

**Verify the persisted value (mirror of Step 5's read-back):**

**On Windows:**

```powershell
$verifiedRoot = [Environment]::GetEnvironmentVariable('MCP_FS_ROOT','User')
if ($verifiedRoot) { Write-Host "Verified: MCP_FS_ROOT = $verifiedRoot" }
else { Write-Host "ERROR: MCP_FS_ROOT not found in user scope. Re-check the command above." }
```

**On macOS/Linux:** open a NEW terminal (the current one won't see the variable yet), then `echo $MCP_FS_ROOT` — it should print the path you set. If empty, check the profile line and re-source it (`source ~/.zshrc` / `source ~/.bashrc`; fish: `echo $MCP_FS_ROOT` works immediately since `set -Ux` is universal).

---

### Step 8: Summary and completion

Provide a short summary:

> **Setup Complete**
>
> **CONTEXT7_API_KEY:** [if set: set with 4 leading chars masked (c7...); if skipped: not set — keyless mode active]
>
> **MCP_FS_ROOT:** [if set: "set to <path>"; if using default: "using default (current project directory)"]
>
> **Next steps:**
> 1. **Close your current terminal and open a new one** — environment variables are captured at process start.
> 2. **Restart Claude Code** — the MCP servers read the variables on launch.
>
> **To undo (remove these settings):**
>
> **Windows:**
> ```powershell
> [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'User')
> [Environment]::SetEnvironmentVariable('MCP_FS_ROOT', $null, 'User')
> ```
>
> **macOS/Linux (bash/zsh):** — EXAMPLE undo commands
> ```bash
> # EXAMPLE: Remove the export lines from profile files (portable method)
> grep -v '^export CONTEXT7_API_KEY=' ~/.bashrc > ~/.bashrc.tmp && mv ~/.bashrc.tmp ~/.bashrc
> grep -v '^export MCP_FS_ROOT=' ~/.bashrc > ~/.bashrc.tmp && mv ~/.bashrc.tmp ~/.bashrc
> grep -v '^export CONTEXT7_API_KEY=' ~/.bash_profile > ~/.bash_profile.tmp && mv ~/.bash_profile.tmp ~/.bash_profile
> grep -v '^export MCP_FS_ROOT=' ~/.bash_profile > ~/.bash_profile.tmp && mv ~/.bash_profile.tmp ~/.bash_profile
> grep -v '^export CONTEXT7_API_KEY=' ~/.zshrc > ~/.zshrc.tmp && mv ~/.zshrc.tmp ~/.zshrc
> grep -v '^export MCP_FS_ROOT=' ~/.zshrc > ~/.zshrc.tmp && mv ~/.zshrc.tmp ~/.zshrc
> ```
>
> **Fish:** — EXAMPLE undo commands
> ```fish
> # EXAMPLE: Remove environment variables
> set -e CONTEXT7_API_KEY
> set -e MCP_FS_ROOT
> ```

---

## Security rules (non-negotiable)

- **Validate all inputs before persistence:**
  - **CONTEXT7_API_KEY token:** Must match `^[A-Za-z0-9_-]+$` (alphanumeric, underscore, hyphen only). Reject any token containing spaces, special characters, or metacharacters. Refuse persistence and display an error message if validation fails.
  - **MCP_FS_ROOT path:** Must NOT contain backticks, double-quotes, dollar signs, or newlines; backslashes are additionally forbidden on macOS/Linux/fish (the value is re-parsed by the shell at every login) but ALLOWED on Windows (persistence uses a .NET API with no shell parsing, and backslash is the native path separator). Spaces, forward slashes, colons, hyphens, and underscores are always allowed. Refuse persistence and display an error message if validation fails.
- **Never** print a found token in full — always mask to 4 leading characters only.
- **Never** persist tokens or secrets to any file in any project directory.
- **Never** write tokens to `settings.json`, `.mcp.json`, or configuration files.
- **Never** put tokens in Claude Code's session without explicit warning — warn the user first if Option C is chosen.
- **Prevent duplicate lines** in shell profiles by checking if the export line already exists before appending (using grep with `||` guard).
- **Clean up sensitive buffers:** On Windows, wrap SecureString marshalling in try/finally and call `Marshal.ZeroFreeCoTaskMemUnicode` or clear the variable with `Remove-Variable`.
- The plugin config references `CONTEXT7_API_KEY` by name only; the variable's **value** must live in the system's user-scope environment store (Windows registry or shell profile).
