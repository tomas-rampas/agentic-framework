#Requires -Version 7.0
# pretooluse-code-review-gate.ps1 - blocking PreToolUse hook (matcher: Bash|PowerShell).
#
# PowerShell twin of pretooluse-code-review-gate.sh; the .sh is the reference
# implementation and the two must produce byte-identical deny output.
#
# Denies a shell command that opens a pull/merge request (gh pr create|new,
# glab mr create|new) or pushes to main/master (git push, force included)
# unless a code-review-gatekeeper sub-agent has recorded VERDICT: APPROVED for
# the exact commit (HEAD) against the exact destination, with a reviewed range
# (<merge-base>..<head-sha>) that binds the approval to the commits being sent,
# in the marker <state>/code-review/<session_id> written by record-subagent-run
# (read here, never written). Grammar: decision S of specs/code-review-gate.md
# (a whitelist of plain forms); the unlock rule is REQ-004. State dir:
# CLAUDE_STATE_DIR, else $HOME/.claude/.state.
#
# SECURITY: the command string is untrusted data. It is NEVER evaluated or
# executed: no Invoke-Expression, no call operator on any part of it, no
# cmd /c. The gate does not try to understand shell text. It:
#  1. (S.1) decides whether the text is a candidate at all: continuations
#     joined, CRLF collapsed, ${...} removed, quotes, backslashes and backticks
#     removed, then the words git+push or gh/glab+create/new (git, gh and glab
#     case-insensitive). Anything else exits 0 with no git call (fast path).
#     Over 64 KB (bytes) the same test decides: match denies (W_SIZE), else exit 0.
#  2. (S.2) splits the raw text with the class GateTok, a line-for-line port of
#     the .sh awk TOK_PROG: it works on the command's UTF-8 bytes (one char per
#     byte, the awk LC_ALL=C semantics) over whitespace and quotes only. Every
#     accepted token is a literal word: any of $ ` { } ( ) * ? [ < | & ; # or a
#     control character anywhere (quoted or not, except inside a clean quoted
#     string), other than one && or ; joiner and trailing redirections, makes
#     the text not plain. A backslash is literal in the PowerShell dialect
#     (tool_name PowerShell) and allowed only inside single quotes otherwise.
#  3. accepts exactly: [cd <dir> && | cd <dir>; | Set-Location <dir>;]
#     git [-C <dir>] push [allowlisted options] [<remote> [<refspec>]], or
#     gh pr create|new ... / glab mr create|new ... (one location prefix at
#     most). Every other candidate is denied W_PLAIN (S.3).
#  4. (S.4) judges the plain command with read-only git questions (rev-parse,
#     symbolic-ref, remote, rev-list, merge-base, config); no network. A
#     wall-clock budget of 8 s from hook start denies any candidate still
#     undecided (W_TIME). On Windows an MSYS absolute path (/c/...) is mapped
#     to its drive form, else through cygpath -w when present.
#
# Always exits 0. Output nothing to allow; to deny print the single-line JSON
# hookSpecificOutput permissionDecision deny. Fail-open (exit 0, no output):
# AF_CODE_REVIEW_GATE=off, malformed JSON, non-object tool_input, missing or
# non-string command, empty session_id after sanitising (checked before the
# candidate and size tests), a push whose payload cwd is not inside a git
# repository (git rev-parse --git-dir fails), a repository with no refs at all
# (an unborn HEAD in a repository that has other refs is gated), any unexpected
# internal error. A bare repository or a directory inside .git is denied W_LOC.
# Not fail-open: a non-plain candidate (W_PLAIN), a cd/-C directory that is
# missing or not a git work tree (W_LOC), a pull/merge request from a directory
# that is not a git work tree (W_NOREPO).

$script:SW = [System.Diagnostics.Stopwatch]::StartNew()

# Port of TOK_PROG (pretooluse-code-review-gate.sh). Input: the command's UTF-8
# bytes, one char per byte. Out: W<word> / O<joiner> entries; Scan returns
# $false when the text is not plain.
class GateTok {
    [System.Collections.Generic.List[string]]$Out = [System.Collections.Generic.List[string]]::new()
    [bool]$Psd = $false
    [bool]$Rt = $false
    [bool]$Nr = $false
    [bool]$Wq = $false
    [bool]$Qpre = $false
    [bool]$Sl = $false

    static [bool] Ctrl([int]$c) { return (($c -ge 1 -and $c -lt 32 -and $c -ne 9) -or $c -eq 127) }
    static [bool] Badc([int]$c) { return ('$`{}()*?[<|&;#'.IndexOf([char]$c) -ge 0) -or [GateTok]::Ctrl($c) }

    [void] Emit([string]$w) {
        $qp = $this.Qpre; $this.Qpre = $false; $this.Sl = $false
        if ($w.Length -eq 0 -and -not $this.Wq) { throw 'BAD' }
        if ($this.Rt) { $this.Rt = $false; return }
        if ($this.Nr) { throw 'BAD' }
        if ($this.Psd -and $w.Length -gt 1 -and [int]$w[0] -eq 64 -and -not $this.Wq) { throw 'BAD' }
        # a Bash word with a quote before its first unquoted slash is not tilde-expanded
        # by the shell: mark a leading tilde so a quoted directory is not read as HOME
        # (S.3-bis e, n)
        if (-not $this.Psd -and $qp -and $w.Length -gt 0 -and [int]$w[0] -eq 126) { $w = [string][char]2 + $w }
        $this.Out.Add('W' + $w)
    }

    # a PowerShell word that begins with a quoted string may not continue (S.3-bis t)
    hidden [void] ContFail([string]$s, [int]$p) {
        if ($p -ge $s.Length) { return }
        $x = [int]$s[$p]
        if ($x -ne 32 -and $x -ne 9 -and $x -ne 59 -and -not ($x -eq 38 -and $p + 1 -lt $s.Length -and [int]$s[$p + 1] -eq 38)) { throw 'BAD' }
    }

    [void] Op([string]$o) {
        if ($this.Nr -or $this.Rt) { throw 'BAD' }
        $this.Out.Add('O' + $o)
    }

    [bool] Scan([string]$s0, [bool]$psd) {
        $this.Psd = $psd
        try {
            $this.Run($s0)
            return $true
        } catch {
            return $false
        }
    }

    hidden [void] Run([string]$s0) {
        $s = [regex]::Replace($s0, '^[ \t\r\n]+', '')
        $s = [regex]::Replace($s, '[ \t\r\n]+\z', '')
        # fast path (speed only): a text of nothing but letters, digits and . _ / : = + % ~ ^ ! -
        # with blanks has no quote, operator, redirection or special character, so the
        # loop below would return exactly its blank-separated words
        if ([regex]::IsMatch($s, '^[A-Za-z0-9._/:=+%~^!\- \t]*\z')) {
            foreach ($fw in $s.Split([char[]]@(' ', "`t"), [System.StringSplitOptions]::RemoveEmptyEntries)) { $this.Out.Add('W' + $fw) }
            return
        }
        $n = $s.Length; $i = 0
        $cur = [System.Text.StringBuilder]::new()
        $inw = $false; $q = 0; $qbeg = $false
        $rx = if ($this.Psd) { [regex]'\G[0-9*]?>>?(&[0-9])?' } else { [regex]'\G[0-9]?>>?(&[0-9])?' }
        while ($i -lt $n) {
            $c = [int]$s[$i]
            if ($q -ne 0) {
                if ($c -eq $q) {
                    if ($this.Psd -and $i + 1 -lt $n -and [int]$s[$i + 1] -eq $q) { [void]$cur.Append([char]$c); $i += 2; continue }
                    $q = 0
                    if ($qbeg) { $this.ContFail($s, $i + 1) }
                    $qbeg = $false; $i++; continue
                }
                if ([GateTok]::Badc($c)) { throw 'BAD' }
                if ($c -eq 92 -and -not $this.Psd -and $q -eq 34) { throw 'BAD' }
                if ($this.Psd -and $c -ge 128) { throw 'BAD' }
                [void]$cur.Append([char]$c); $i++; continue
            }
            if ($c -eq 32 -or $c -eq 9) {
                if ($inw) { $this.Emit($cur.ToString()); [void]$cur.Clear(); $inw = $false; $this.Wq = $false }
                $i++; continue
            }
            if ($c -eq 34 -or $c -eq 39) {
                # a closed quoted string with no $ ` backslash or control character is one
                # literal token: the banned characters inside it are data (S.2)
                if (-not $this.Psd -and -not $this.Sl) { $this.Qpre = $true }
                $qb = ($this.Psd -and -not $inw)
                $k = $i + 1
                while ($k -lt $n) {
                    $ch = [int]$s[$k]
                    if ($ch -eq $c) {
                        if ($this.Psd -and $k + 1 -lt $n -and [int]$s[$k + 1] -eq $c) { $k += 2; continue }
                        break
                    }
                    $k++
                }
                if ($k -lt $n) {
                    $raw = $s.Substring($i + 1, $k - $i - 1)
                    $clean = ($raw.IndexOf([char]'$') -lt 0 -and $raw.IndexOf([char]'`') -lt 0 -and $raw.IndexOf([char]'\') -lt 0)
                    if ($clean) {
                        foreach ($z in $raw.ToCharArray()) { if ([GateTok]::Ctrl([int]$z)) { $clean = $false; break } }
                    }
                    if ($clean) {
                        if ($this.Psd) { $qs = [string][char]$c; $raw = $raw.Replace($qs + $qs, $qs) }
                        if ($qb) { $this.ContFail($s, $k + 1) }
                        [void]$cur.Append($raw); $inw = $true; $this.Wq = $true; $i = $k + 1; continue
                    }
                }
                $q = $c; $qbeg = $qb; $inw = $true; $this.Wq = $true; $i++; continue
            }
            if ($c -eq 38 -and $i + 1 -lt $n -and [int]$s[$i + 1] -eq 38) {
                if ($inw) { $this.Emit($cur.ToString()); [void]$cur.Clear(); $inw = $false; $this.Wq = $false }
                $this.Op('&&'); $i += 2; continue
            }
            if ($c -eq 59) {
                if ($inw) { $this.Emit($cur.ToString()); [void]$cur.Clear(); $inw = $false; $this.Wq = $false }
                $this.Op(';'); $i++; continue
            }
            if (-not $inw) {
                $m = $rx.Match($s, $i)
                if ($m.Success) {
                    if ($this.Rt) { throw 'BAD' }
                    $tk = $m.Value; $i += $m.Length; $this.Nr = $true
                    if ($tk.IndexOf([char]'&') -ge 0) {
                        if ($i -lt $n) {
                            $nx = [int]$s[$i]
                            if ($nx -ne 32 -and $nx -ne 9) { throw 'BAD' }
                        }
                    } else { $this.Rt = $true }
                    continue
                }
            }
            if ($c -eq 62) { throw 'BAD' }
            if ($c -eq 92 -and -not $this.Psd) { throw 'BAD' }
            if ($this.Psd -and $c -eq 44) { throw 'BAD' }
            if ($this.Psd -and $c -ge 128) { throw 'BAD' }
            if ([GateTok]::Badc($c)) { throw 'BAD' }
            if ($c -eq 47) { $this.Sl = $true }
            [void]$cur.Append([char]$c); $inw = $true; $i++
        }
        if ($q -ne 0) { throw 'BAD' }
        if ($inw) { $this.Emit($cur.ToString()) }
        if ($this.Rt) { throw 'BAD' }
    }
}

# --- deny helper and wordings ------------------------------------------------------
function Send-Deny {
    # $Kind command kind, $Sentence specific sentence, $Target review target
    param([string]$Kind, [string]$Sentence, [string]$Target)
    $r = "Code-review gate: ${Kind} denied. ${Sentence} Review target: ${Target}. To unlock: launch the code-review-gatekeeper sub-agent (Agent tool, subagent_type: code-review-gatekeeper) and have it apply agentic-framework:code-review to that target (${Target}); the command is allowed once VERDICT: APPROVED is recorded at the current HEAD against that base. Setting AF_CODE_REVIEW_GATE=off in the launch environment disables this gate (a restart is needed)."
    $r = [regex]::Replace($r, '[^\x20-\x7e]', '')
    $r = [regex]::Replace($r, '["<>&]', '')
    $json = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"' + $r.Replace('\', '\\') + '"}}'
    [Console]::Out.Write($json + "`n")
    [Console]::Out.Flush()
    exit 0
}

$script:K_ANY = 'git push or pull request creation'
$script:T_ANY = 'the current branch against its destination'
$script:W_PLAIN = 'The command text is not a plain push or pull request command. The gate allows a push or a PR/MR creation only as its own command with literal names: git push REMOTE REFSPEC, gh pr create ..., glab mr create ..., optionally after one cd DIR (joined by a double ampersand or a semicolon) or as git -C DIR push. Split chained commands, variables, substitutions, wrappers and scripts into separate plain commands; pass a multi-line PR body with --body-file. If this command is not a push or a PR creation, its text still mentions one: reword it or move the text to a file.'
$script:W_SIZE = 'The command text is unresolvable: it is longer than 64 KB and appears to contain a push or a pull request creation, so the gate does not parse it. Split it into separate, smaller commands.'
$script:W_TIME = 'The command text is unresolvable: the gate ran out of time deciding it (more than 8 seconds). Split it into separate, smaller commands.'
$script:W_LOC = 'The command text is unresolvable: the cd, Set-Location or git -C directory does not exist or is not a git work tree, so the repository is unknown. Run the command from the repository itself.'
$script:W_NOREPO = 'The command text is unresolvable: the pull or merge request is created from a directory that is not a git work tree, so the commit to propose cannot be identified. Run it from the repository whose branch is proposed.'
$script:W_REFMAP = 'The push destination cannot be resolved: a remote.REMOTE.push entry matches this branch but does not name a single destination branch. Push with an explicit source:destination refspec.'

$script:Ord = [System.StringComparison]::Ordinal

function Test-StartsWith([string]$S, [string]$P) { return $S.StartsWith($P, $script:Ord) }
function Test-Eq([string]$A, [string]$B) { return [string]::Equals($A, $B) }
function Get-OrDefault([string]$V, [string]$D) { if (-not [string]::Equals($V, '')) { return $V } return $D }
function Test-Time {
    if ($script:SW.Elapsed.TotalSeconds -ge 8) { Send-Deny $script:K_ANY $script:W_TIME $script:T_ANY }
}
function Send-NotPlain { Send-Deny $script:K_ANY $script:W_PLAIN $script:T_ANY }
function Test-In([string]$S, [string[]]$List) {
    foreach ($x in $List) { if ([string]::Equals($S, $x)) { return $true } }
    return $false
}
# S.1 candidate test on one spelling (bytes as chars): port of the awk scan(). A word
# is a maximal run of letters and digits. The test is linear in the text length
# (decision S 3-bis s): whole-text regex scans, no per-word PowerShell loop, so a
# 300 KB text of short words costs milliseconds. The flags are order independent.
# A push is "eligible" unless a dot follows it directly, or its two previous words
# are exactly "git" then "stash" (case-sensitive).
$script:RxOpt = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
$script:RxOptI = $script:RxOpt -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
$script:RxGit = [regex]::new('(?<![A-Za-z0-9])git(?![A-Za-z0-9])', $script:RxOptI)
$script:RxGh = [regex]::new('(?<![A-Za-z0-9])(?:gh|glab)(?![A-Za-z0-9])', $script:RxOptI)
$script:RxPush = [regex]::new('(?<![A-Za-z0-9])push(?![A-Za-z0-9.])', $script:RxOpt)
# S.1 stash exemption, anchored: the one push that is the third word of a text beginning
# (after whitespace only) with "git stash" is exempt; its index is the prefix length.
$script:RxStashPrefix = [regex]::new('\A[ \t\r\n]*git[^A-Za-z0-9]+stash[^A-Za-z0-9]+', $script:RxOpt)
$script:RxPr = [regex]::new('(?<![A-Za-z0-9])(?:pr|mr)(?![A-Za-z0-9])', $script:RxOpt)
$script:RxCreate = [regex]::new('(?<![A-Za-z0-9])(?:create|new)(?![A-Za-z0-9])', $script:RxOpt)
function Test-Cand([string]$T) {
    if ($script:RxGit.IsMatch($T)) {
        $ex = -1
        $sm = $script:RxStashPrefix.Match($T)
        if ($sm.Success) { $ex = $sm.Length }
        foreach ($pm in $script:RxPush.Matches($T)) { if ($pm.Index -ne $ex) { return $true } }
    }
    return ($script:RxGh.IsMatch($T) -and $script:RxPr.IsMatch($T) -and $script:RxCreate.IsMatch($T))
}
# Remove ${...} in linear time: only while a closing brace remains after the opener.
function Get-WithoutBraceExpansion([string]$T) {
    $lc = $T.LastIndexOf('}')
    if ($lc -lt 0) { return $T }
    $sb = [System.Text.StringBuilder]::new()
    $pos = 0
    while ($true) {
        $p = $T.IndexOf('${', $pos, $script:Ord)
        if ($p -lt 0 -or $lc -lt $p + 2) { break }
        $e = $T.IndexOf('}', $p + 2)
        [void]$sb.Append($T.Substring($pos, $p - $pos))
        $pos = $e + 1
    }
    [void]$sb.Append($T.Substring($pos, $T.Length - $pos))
    return $sb.ToString()
}
# push_val: in the PowerShell dialect an option value is held to the push alphabet.
function Test-PushVal([string]$V) {
    if ($script:dialectPs -and [regex]::IsMatch($V, '[^A-Za-z0-9._/@:+=%,-]')) { Send-NotPlain }
}

# --- state ---------------------------------------------------------------------------
$script:gdir = ''; $script:headsha = ''; $script:branch = ''; $script:remote = ''
$script:loc = ''; $script:hasLoc = $false
$script:PREP_DONE = $false; $script:PREP_WT = 0; $script:memoHead = ''; $script:memoRb = ''
$script:memoRl = $false; $script:memoRemotes = @()
$script:CFG = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
$script:chainDone = $false
$script:RR = ''; $script:RPD = ''; $script:ROR_R = ''; $script:ROR_B = ''; $script:TGT = ''; $script:CO = ''; $script:PDD = ''; $script:MR = ''
$script:cAll = $false; $script:cAny = $false; $script:anyBare = $false
$script:nrefs = [System.Collections.Generic.List[object]]::new()
$script:cygpath = $null; $script:cygpathProbed = $false

# --- helpers -------------------------------------------------------------------------
function Invoke-Git {
    # Read-only git in $Dir; the output with trailing newlines removed, or $null on a non-zero exit.
    param([string]$Dir, [string[]]$GitArgs)
    $ErrorActionPreference = 'Continue'
    $out = & git -C $Dir @GitArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ((@($out) -join "`n").TrimEnd("`n"))
}

function Invoke-GitRc {
    # Read-only git in $Dir, output discarded; the integer exit status.
    param([string]$Dir, [string[]]$GitArgs)
    $ErrorActionPreference = 'Continue'
    $null = & git -C $Dir @GitArgs 2>$null
    return [int]$LASTEXITCODE
}

# Windows only: an MSYS absolute path /x/... becomes X:/...; another /... goes
# through cygpath -w when present; $null when it cannot be mapped.
function Convert-MsysPath([string]$P) {
    if (-not $IsWindows -or -not (Test-StartsWith $P '/')) { return $P }
    $m = [regex]::Match($P, '^/([A-Za-z])(/|\z)')
    if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() + ':/' + $P.Substring($m.Length) }
    if (-not $script:cygpathProbed) {
        $script:cygpathProbed = $true
        $cp = Get-Command cygpath -CommandType Application -ErrorAction Ignore | Select-Object -First 1
        if ($cp) { $script:cygpath = $cp.Source }
    }
    if (-not $script:cygpath) { return $null }
    $ErrorActionPreference = 'Continue'
    $o = & $script:cygpath -w -- $P 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $o) { return $null }
    return [string](@($o)[0])
}

# Resolve-Loc <kind label>: gdir = the location prefix's directory (or the payload
# cwd); a location that is not an existing directory denies W_LOC.
function Resolve-Loc([string]$Label) {
    $script:gdir = $script:cwd0
    if (-not $script:hasLoc) { return }
    $d = $script:loc
    $locT = 'HEAD vs its destination'
    if ((Test-Eq $d '~') -or (Test-StartsWith $d '~/') -or (Test-StartsWith $d '~\')) {
        $hm = $env:HOME
        if (-not $hm) { $hm = $env:USERPROFILE }
        if (-not $hm) { Send-Deny $Label $script:W_LOC $locT }
        $d = if (Test-Eq $d '~') { $hm } else { $hm + '/' + $d.Substring(2) }
    } elseif (-not [regex]::IsMatch($d, '^(/|[A-Za-z]:|\\)')) {
        $d = "$($script:cwd0)/$d"
    }
    $d = Convert-MsysPath $d
    if ($null -eq $d -or -not [System.IO.Directory]::Exists($d)) { Send-Deny $Label $script:W_LOC $locT }
    $script:gdir = $d
}

function Import-Remote {
    if (-not $script:memoRl) {
        $o = Invoke-Git $script:gdir @('remote')
        if ($null -eq $o) { $script:memoRemotes = @() }
        else { $script:memoRemotes = @($o -split "[ `t`n]+" | Where-Object { -not [string]::Equals($_, '') }) }
        $script:memoRl = $true
    }
}

function Test-Remote([string]$Name) {
    foreach ($r in $script:memoRemotes) { if ([string]::Equals($r, $Name)) { return $true } }
    return $false
}

# Get-CfgAll <key>: every value of the git config key in gdir, newline separated (memoised).
function Get-CfgAll([string]$Key) {
    if ($script:CFG.ContainsKey($Key)) { return $script:CFG[$Key] }
    $v = Invoke-Git $script:gdir @('config', '--get-all', $Key)
    if ($null -eq $v) { $v = '' }
    $script:CFG[$Key] = $v
    return $v
}

function Get-LastLine([string]$S) {
    $p = $S.LastIndexOf("`n")
    if ($p -ge 0) { return $S.Substring($p + 1) }
    return $S
}

# Sets headsha, branch and PREP_WT for gdir (memoised); returns $false when the
# candidate cannot be judged (not a work tree, or an unborn HEAD).
function Initialize-Repo {
    if (-not $script:PREP_DONE) {
        Test-Time
        $script:PREP_DONE = $true
        $o = Invoke-Git $script:gdir @('rev-parse', '--is-inside-work-tree', 'HEAD')
        if ($null -ne $o) {
            $nl = $o.IndexOf("`n")
            $first = if ($nl -ge 0) { $o.Substring(0, $nl) } else { $o }
            if (Test-Eq $first 'true') { $script:PREP_WT = 1; $script:memoHead = $(if ($nl -ge 0) { $o.Substring($nl + 1) } else { $o }) }
        } else {
            Test-Time
            $o = Invoke-Git $script:gdir @('rev-parse', '--is-inside-work-tree')
            if (Test-Eq $o 'true') { $script:PREP_WT = 1 }
        }
        Test-Time
        if (-not (Test-Eq $script:memoHead '')) {
            $b = Invoke-Git $script:gdir @('symbolic-ref', '--short', '--quiet', 'HEAD')
            $script:memoRb = if ($null -eq $b) { '' } else { $b }
        }
    }
    $script:headsha = $script:memoHead
    $script:branch = $script:memoRb
    return ($script:PREP_WT -eq 1 -and -not (Test-Eq $script:headsha ''))
}

# Test-NeedRepo: Initialize-Repo; $false (fail open) when the payload's own cwd is
# not a work tree or HEAD is unborn; a cd/-C directory that is not a git work tree
# denies W_LOC.
function Test-NeedRepo {
    if (Initialize-Repo) { return $true }
    Test-Time
    $unres = "HEAD vs $(Get-OrDefault $script:remote 'origin')/an unresolved destination"
    if ((Invoke-GitRc $script:gdir @('rev-parse', '--git-dir')) -ne 0) {
        # not a repository at all: the payload cwd fails open, a cd/-C directory denies
        if (-not $script:hasLoc) { return $false }
        Send-Deny 'git push' $script:W_LOC $unres
    }
    # a bare repository or a directory inside .git is gated like any repository
    if ($script:PREP_WT -ne 1) { Send-Deny 'git push' $script:W_LOC $unres }
    # unborn HEAD: only a repository with no refs at all fails open
    $nr = Invoke-Git $script:gdir @('for-each-ref', '--count=1', '--format=x')
    if ($null -eq $nr -or (Test-Eq $nr '')) { return $false }
    $script:headsha = ''
    $b = Invoke-Git $script:gdir @('symbolic-ref', '--short', '--quiet', 'HEAD')
    $script:branch = if ($null -eq $b) { '' } else { $b }
    $script:memoRb = $script:branch
    return $true
}

# Get-RemoteOfRef <full ref>: the longest configured remote whose refs/remotes/<r>/ prefixes it.
function Get-RemoteOfRef([string]$Full) {
    if (-not (Test-StartsWith $Full 'refs/remotes/')) { return $false }
    $rest = $Full.Substring(13); $script:ROR_R = ''; $script:ROR_B = ''
    foreach ($r in $script:memoRemotes) {
        if (Test-StartsWith $rest "$r/") {
            if ($r.Length -gt $script:ROR_R.Length) { $script:ROR_R = $r; $script:ROR_B = $rest.Substring($r.Length + 1) }
        }
    }
    return (-not (Test-Eq $script:ROR_R ''))
}

# Resolve-Chain: RR = the remote a push with no remote named goes to (@{push},
# branch.<b>.pushRemote, remote.pushDefault, branch.<b>.remote, origin); RPD =
# the destination @{push} or @{upstream} names, remote prefix removed.
function Resolve-Chain {
    Import-Remote
    if ($script:chainDone) { return }
    $script:RR = ''; $script:RPD = ''
    Test-Time
    $b = $script:branch
    if (-not (Test-Eq $b '')) {
        $full = Invoke-Git $script:gdir @('rev-parse', '--symbolic-full-name', "$b@{push}")
        if ($null -eq $full) { $full = '' }
        if (Get-RemoteOfRef $full) { $script:RR = $script:ROR_R; $script:RPD = $script:ROR_B }
        if (Test-Eq $script:RR '') {
            foreach ($key in @("branch.$b.pushRemote", 'remote.pushDefault', "branch.$b.remote")) {
                $v = Invoke-Git $script:gdir @('config', '--get', $key)
                if ($null -ne $v -and -not (Test-Eq $v '')) { $script:RR = $v; break }
            }
        }
        if (Test-Eq $script:RPD '') {
            $full = Invoke-Git $script:gdir @('rev-parse', '--symbolic-full-name', "$b@{upstream}")
            if ($null -eq $full) { $full = '' }
            if (Test-StartsWith $full 'refs/heads/') { $script:RPD = $full.Substring(11) }
            elseif (Get-RemoteOfRef $full) { $script:RPD = $script:ROR_B }
        }
    } else {
        $v = Invoke-Git $script:gdir @('config', '--get', 'remote.pushDefault')
        $script:RR = if ($null -eq $v) { '' } else { $v }
    }
    if (Test-Eq $script:RR '') { $script:RR = 'origin' }
    $script:chainDone = $true
}

function Resolve-PushTarget([string]$Dest) {
    $script:TGT = "$(Get-OrDefault $script:branch 'HEAD') vs $($script:remote)/$Dest"
    $n = Invoke-Git $script:gdir @('rev-list', '--count', '--end-of-options', "refs/remotes/$($script:remote)/$Dest..HEAD")
    if ($null -ne $n -and [regex]::IsMatch($n, '^[0-9]+\z')) { $script:TGT = "$($script:TGT) ($n commits ahead)" }
}

function Resolve-CommitOf([string]$Rev) {
    $o = Invoke-Git $script:gdir @('rev-parse', '--verify', '--quiet', '--end-of-options', "$Rev^{commit}")
    $script:CO = if ($null -eq $o) { '' } else { $o }
}

function Get-RevOrEmpty([string]$Ref) {
    $o = Invoke-Git $script:gdir @('rev-parse', '--verify', '--quiet', '--end-of-options', $Ref)
    if ($null -eq $o) { return '' }
    return $o
}

# Unlock rule (REQ-004, I-ter.8). Returns when the marker unlocks; else denies. $Mode: push | pr.
function Test-Marker([string]$Kind, [string]$Target, [string]$Dest, [string]$Mode) {
    Test-Time
    $mv = ''; $mh = ''; $mt = ''
    if (-not [System.IO.File]::Exists($script:marker)) {
        Send-Deny $Kind 'No code-review-gatekeeper review is recorded for this session, so nothing vouches for this change.' $Target
    }
    $txt = $null
    try { $txt = [System.IO.File]::ReadAllText($script:marker, [System.Text.UTF8Encoding]::new($false)) } catch { $txt = $null }
    if ($null -ne $txt) {
        foreach ($ml in $txt.Replace([string][char]0, '').Split("`n")) {
            if ($ml.EndsWith("`r", $script:Ord)) { $ml = $ml.Substring(0, $ml.Length - 1) }
            if (Test-StartsWith $ml 'verdict=') { if (Test-Eq $mv '') { $mv = $ml.Substring(8) } }
            elseif (Test-StartsWith $ml 'head=') { if (Test-Eq $mh '') { $mh = $ml.Substring(5) } }
            elseif (Test-StartsWith $ml 'target=') { if (Test-Eq $mt '') { $mt = $ml.Substring(7) } }
        }
    }
    if (-not (Test-Eq $mv 'APPROVED') -and -not (Test-Eq $mv 'CHANGES_REQUIRED')) {
        Send-Deny $Kind 'No code-review-gatekeeper review verdict is recorded for this session, so nothing vouches for this change.' $Target
    }
    $ckBase = ''; $ckMb = ''; $ckHd = ''
    if (-not ((Test-StartsWith $mt 'uncommitted @ ') -or (Test-StartsWith $mt 'paths '))) {
        $m = [regex]::Match($mt, '^[^ ].* vs ([^ ]+) \(.*$')
        if ($m.Success) { $ckBase = $m.Groups[1].Value }
        $m = [regex]::Match($mt, '^[^ ].* vs [^ ]+ \(([0-9a-f]{7,40})\.\.([0-9a-f]{7,40})\).*$')
        if ($m.Success) { $ckMb = $m.Groups[1].Value; $ckHd = $m.Groups[2].Value }
    }
    $hs = $script:headsha
    if (-not (Test-Eq $ckHd '')) {
        Resolve-CommitOf $ckHd
        if (-not (Test-Eq $script:CO $hs)) {
            Send-Deny $Kind "The recorded review is stale: its reviewed range ends at $(Get-OrDefault $script:CO $ckHd) but HEAD is now $hs (a commit, amend or rebase came after the review). Re-run the review at the current HEAD." $Target
        }
    }
    if (-not (Test-Eq $mh $hs)) {
        Send-Deny $Kind "The recorded review is stale: it was made at $(Get-OrDefault $mh 'no recorded head') but HEAD is now $hs (a commit, amend or rebase came after the review). Re-run the review at the current HEAD." $Target
    }
    if (Test-Eq $mv 'CHANGES_REQUIRED') {
        Send-Deny $Kind 'The recorded review at this HEAD returned CHANGES_REQUIRED. Resolve every open finding, then re-run the review.' $Target
    }
    if (Test-Eq $ckBase '') {
        Send-Deny $Kind "The recorded review did not cover the branch against its destination (its target was: $(Get-OrDefault $mt 'none recorded')). Only a review of the branch against the destination unlocks this." $Target
    }
    # base: a leading <r>/ is removed when <r> is the resolved remote, or for a PR the
    # remote refs/remotes/origin/HEAD points into (I-ter.11)
    $sb = $ckBase; $rr = $script:remote; $oh = ''
    if (Test-Eq $Mode 'pr') {
        Import-Remote
        $ohf = Invoke-Git $script:gdir @('symbolic-ref', '-q', 'refs/remotes/origin/HEAD')
        if ($null -eq $ohf) { $ohf = '' }
        if (Get-RemoteOfRef $ohf) { $oh = $script:ROR_R }
    }
    if (Test-StartsWith $sb "$($script:remote)/") { $sb = $sb.Substring($script:remote.Length + 1) }
    elseif (-not (Test-Eq $oh '') -and (Test-StartsWith $sb "$oh/")) { $sb = $sb.Substring($oh.Length + 1); $rr = $oh }
    if (-not (Test-Eq $sb $Dest)) {
        Send-Deny $Kind "Base mismatch: the recorded review compared the branch with $ckBase, but this command lands on $Dest. Re-run the review against $Dest." $Target
    }
    if (Test-Eq $ckHd '') {
        Send-Deny $Kind 'The recorded review is stale: its target names no reviewed range (merge-base..head), so the approval cannot be bound to the commits being sent. Re-run the review at the current HEAD.' $Target
    }
    Resolve-CommitOf $ckMb; $mbc = $script:CO
    # the reviewed range must start on the remote-tracking ref of the destination only
    $refs = @("refs/remotes/$rr/$Dest")
    if ((Test-Eq $Mode 'pr') -and -not (Test-Eq $oh '') -and -not (Test-Eq $oh $rr)) { $refs += "refs/remotes/$oh/$Dest" }
    # an empty range unlocks nothing while HEAD differs from the destination's remote tip
    if (Test-Eq $mbc $hs) {
        $tip = Get-RevOrEmpty "refs/remotes/$rr/$Dest"
        if (-not (Test-Eq $tip $hs)) {
            Send-Deny $Kind "The recorded review is stale: its reviewed range $ckMb..$ckHd is empty while HEAD differs from $rr/$Dest (commits ahead or behind). Re-run the review at the current HEAD." $Target
        }
    }
    $ok = $false
    if (-not (Test-Eq $mbc '')) {
        foreach ($r in $refs) {
            if (Test-Eq $r '') { continue }
            if ($null -ne (Invoke-Git $script:gdir @('merge-base', '--is-ancestor', '--end-of-options', $mbc, $r))) { $ok = $true; break }
        }
    }
    if (-not $ok) {
        Send-Deny $Kind "The recorded review is stale: its reviewed range starts at $ckMb, which is not an ancestor of $rr/$Dest (the remote-tracking ref of the destination), so it does not cover every commit being sent. Re-run the review against $rr/$Dest." $Target
    }
    # what the forge builds the request from must be what was reviewed
    if ((Test-Eq $Mode 'pr') -and -not (Test-Eq $script:branch '')) {
        $hr = Get-RevOrEmpty "refs/remotes/$($script:remote)/$($script:branch)"
        if (-not (Test-Eq $hr '') -and -not (Test-Eq $hr $hs)) {
            Send-Deny $Kind "The recorded review is stale for this request: the remote branch $($script:remote)/$($script:branch) is at $hr, not at HEAD $hs, so the request would be built from commits other than the reviewed ones. Push HEAD to $($script:remote)/$($script:branch) first, then open the request." $Target
        }
    }
}

function Resolve-PrDefaultDst {
    $d = Invoke-Git $script:gdir @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    if ($null -ne $d -and -not (Test-Eq $d '')) {
        $script:PDD = if (Test-StartsWith $d 'origin/') { $d.Substring(7) } else { $d }
    } elseif ((Invoke-GitRc $script:gdir @('rev-parse', '--verify', '--quiet', 'refs/remotes/origin/main')) -eq 0 -or
              (Invoke-GitRc $script:gdir @('rev-parse', '--verify', '--quiet', 'refs/heads/main')) -eq 0) {
        $script:PDD = 'main'
    } else {
        $script:PDD = 'master'
    }
}

function Get-ShortRef([string]$R) {
    if (Test-StartsWith $R 'refs/heads/') { $R = $R.Substring(11) }
    if (Test-StartsWith $R 'heads/') { $R = $R.Substring(6) }
    return $R
}

# Add-Refspec <refspecs> <mark bare>: appends @(src, dst, bare) to nrefs, sets cAll
# for the matching refspec or a wildcard, cAny when a destination is main, master or
# HEAD, anyBare when a refspec is a bare name other than HEAD.
function Add-Refspec([string[]]$List, [int]$MarkBare) {
    foreach ($r0 in $List) {
        if (Test-Eq $r0 '') { continue }
        $r = if (Test-StartsWith $r0 '+') { $r0.Substring(1) } else { $r0 }
        $b = 0
        if ((Test-Eq $r '') -or (Test-Eq $r ':')) { $script:cAll = $true; continue }
        if ($r.Contains('*')) { $script:cAll = $true; continue }
        $ci = $r.IndexOf([char]':')
        if ($ci -ge 0) { $src = $r.Substring(0, $ci); $dst = $r.Substring($ci + 1) } else { $src = $r; $dst = $r; $b = $MarkBare }
        if (Test-Eq $src '') { continue }
        $src = Get-ShortRef $src
        $dst = Get-ShortRef $dst
        if (Test-Eq $src '@') { $src = 'HEAD' }
        if (Test-Eq $dst '@') { $dst = 'HEAD' }
        if (Test-Eq $src 'HEAD') { $b = 0 }
        if ($b -eq 1) { $script:anyBare = $true }
        if ((Test-Eq $dst 'main') -or (Test-Eq $dst 'master') -or (Test-Eq $dst 'HEAD')) { $script:cAny = $true }
        $script:nrefs.Add(@($src, $dst, $b))
    }
}

# Get-MapRef <full ref> <remote.<r>.push entries>: sets MR to the destination of the
# first entry whose source matches. Returns 0 matched, 1 no entry matches, 2 a
# matching entry whose destination cannot be resolved.
function Get-MapRef([string]$Full, [string[]]$Entries) {
    # any negative entry denies: git reverse-maps negatives through the positive
    # entries and the gate does not model that (S.3-bis o)
    foreach ($e0 in $Entries) {
        if ((Test-StartsWith $e0 '^') -or (Test-StartsWith $e0 '+^')) { return 2 }
    }
    foreach ($e0 in $Entries) {
        if (Test-Eq $e0 '') { continue }
        $e = if (Test-StartsWith $e0 '+') { $e0.Substring(1) } else { $e0 }
        # an entry with no colon is skipped (query_refspecs)
        $ci = $e.IndexOf([char]':')
        if ($ci -lt 0) { continue }
        $s = $e.Substring(0, $ci); $d = $e.Substring($ci + 1)
        $st = $s.IndexOf([char]'*')
        if ($st -ge 0) {
            $pre = $s.Substring(0, $st); $suf = $s.Substring($st + 1)
            if ($suf.Contains('*')) { return 2 }
            if (-not ($Full.Length -ge $pre.Length + $suf.Length -and (Test-StartsWith $Full $pre) -and $Full.EndsWith($suf, $script:Ord))) { continue }
            $mid = $Full.Substring($pre.Length, $Full.Length - $pre.Length - $suf.Length)
            $dt = $d.IndexOf([char]'*')
            if ($dt -lt 0) { return 2 }
            $mr = $d.Substring(0, $dt) + $mid + $d.Substring($dt + 1)
        } else {
            if (-not (Test-Eq $s $Full)) { continue }
            $mr = $d
        }
        $mr = Get-ShortRef $mr
        if ((Test-Eq $mr '') -or $mr.Contains('*')) { return 2 }
        $script:MR = $mr
        return 0
    }
    return 1
}

# Invoke-RemapBare: each bare refspec naming one local branch takes its destination
# from remote.<r>.push (a refmap), else under push.default upstream or tracking from
# a single-valued branch.<src>.merge (I-quater.3). Rewrites nrefs and cAny.
function Invoke-RemapBare {
    $map = Get-CfgAll "remote.$($script:remote).push"
    $pd = Get-LastLine (Get-CfgAll 'push.default')
    $up = [regex]::IsMatch($pd, '^([Uu][Pp][Ss][Tt][Rr][Ee][Aa][Mm]|[Tt][Rr][Aa][Cc][Kk][Ii][Nn][Gg])\z')
    $out = [System.Collections.Generic.List[object]]::new(); $script:cAny = $false
    foreach ($e in $script:nrefs) {
        $s = $e[0]; $d = $e[1]; $b = $e[2]
        if (Test-Eq $s '') { continue }
        if ($b -eq 1 -and (Invoke-GitRc $script:gdir @('rev-parse', '--verify', '--quiet', "refs/heads/$s")) -eq 0) {
            $done = $false
            if (-not (Test-Eq $map '')) {
                $rc = Get-MapRef "refs/heads/$s" @($map.Split("`n"))
                if ($rc -eq 0) { $d = $script:MR; $done = $true }
                elseif ($rc -eq 2) { Send-Deny 'git push' $script:W_REFMAP "$(Get-OrDefault $script:branch 'HEAD') vs $($script:remote)/an unresolved destination" }
            }
            if (-not $done -and $up) {
                $mg = Get-CfgAll "branch.$s.merge"
                if (-not (Test-Eq $mg '') -and -not $mg.Contains("`n")) { $d = Get-ShortRef $mg }
            }
        }
        if ((Test-Eq $d 'main') -or (Test-Eq $d 'master') -or (Test-Eq $d 'HEAD')) { $script:cAny = $true }
        $out.Add(@($s, $d, $b))
    }
    $script:nrefs = $out
}

function Add-ChangedBranch($Pairs) {
    foreach ($b in @('main', 'master')) {
        $l = Invoke-Git $script:gdir @('rev-parse', '--verify', '--quiet', "refs/heads/$b")
        if ($null -eq $l) { continue }
        $rs = Get-RevOrEmpty "refs/remotes/$($script:remote)/$b"
        if (Test-Eq $l $rs) { continue }
        $Pairs.Add(@($b, $b))
    }
}

# --- git push <args> (S.2 option allowlist, S.4 decision) ---------------------------
function Invoke-Push([string[]]$A) {
    $noop = @('-u', '--set-upstream', '-f', '--force', '--force-with-lease', '--follow-tags', '--no-verify', '-q', '--quiet', '-v', '--verbose', '--porcelain')
    $dry = $false; $del = $false; $tags = $false; $mirror = $false; $script:remote = ''; $refs = ''; $npos = 0
    $i = 0; $dpn = 0
    while ($i -lt $A.Count) {
        $t = $A[$i]; $i++
        $dpn++
        if ($dpn % 2000 -eq 0) { Test-Time }
        if (Test-In $t $noop) { continue }
        if (Test-StartsWith $t '--force-with-lease=') { Test-PushVal $t.Substring(19); continue }
        if (Test-StartsWith $t '--push-option=') { Test-PushVal $t.Substring(14); continue }
        if (Test-Eq $t '--tags') { $tags = $true; continue }
        if ((Test-Eq $t '-n') -or (Test-Eq $t '--dry-run')) { $dry = $true; continue }
        if ((Test-Eq $t '-d') -or (Test-Eq $t '--delete')) { $del = $true; continue }
        if (Test-Eq $t '-o') { if ($i -ge $A.Count) { Send-NotPlain }; Test-PushVal $A[$i]; $i++; continue }
        if (Test-StartsWith $t '-') { Send-NotPlain }
        if (Test-Eq $t '') { Send-NotPlain }
        $npos++
        if ($npos -eq 1) { $script:remote = $t }
        elseif ($npos -eq 2) { $refs = $t }
        else { Send-NotPlain }
    }
    # S.2 quoting never relaxes the plain form: after unquoting, the remote and the
    # refspec must still be literal names (a quoted wildcard or space is not plain).
    $alpha = '[^A-Za-z0-9._/@:+=%,-]'
    if ([regex]::IsMatch($script:remote, $alpha)) { Send-NotPlain }
    if ([regex]::IsMatch($refs, $alpha)) { Send-NotPlain }
    if ((Test-Eq $refs ':') -or (Test-Eq $refs '+:')) { Send-NotPlain }
    # git splits a refspec at its last colon, so a second one changes the meaning
    if ($refs.IndexOf([char]':') -ge 0 -and $refs.IndexOf([char]':') -ne $refs.LastIndexOf([char]':')) { Send-NotPlain }
    if ($dry) { exit 0 }
    if ($del) { exit 0 }
    $hasrefs = -not (Test-Eq $refs '')

    # classify the explicit refspec before any git call
    $script:nrefs = [System.Collections.Generic.List[object]]::new(); $script:cAny = $false; $script:anyBare = $false
    if ($hasrefs) { Add-Refspec @($refs) 1 }
    if ($hasrefs -and -not $script:cAny -and -not $script:anyBare) { exit 0 }

    Resolve-Loc 'git push'
    if (-not (Test-NeedRepo)) { exit 0 }
    Import-Remote

    $remoteNamed = -not (Test-Eq $script:remote '')
    $script:RR = ''; $script:RPD = ''
    if (-not $hasrefs -or -not $remoteNamed) { Resolve-Chain }
    if (-not $remoteNamed) { $script:remote = $script:RR }
    if ($script:anyBare) { Invoke-RemapBare }

    # persistent configuration of the remote (I-ter.7): remote.<r>.mirror, remote.<r>.push
    if (-not $hasrefs) {
        $mv = Get-LastLine (Get-CfgAll "remote.$($script:remote).mirror")
        if ([regex]::IsMatch($mv, '^([Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]|1)\z')) { $mirror = $true }
        if (-not $mirror) {
            $pc = Get-CfgAll "remote.$($script:remote).push"
            if (-not (Test-Eq $pc '')) { $hasrefs = $true; Add-Refspec @($pc.Split("`n")) 0 }
        }
    }
    if (-not $hasrefs -and -not $mirror -and $tags) { exit 0 }
    if ($hasrefs -and -not $script:cAll -and -not $mirror -and -not $script:cAny) { exit 0 }

    $pairs = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $script:nrefs) {
        $src = $e[0]; $dst = $e[1]
        if (Test-Eq $src '') { continue }
        if (Test-Eq $dst 'HEAD') { $dst = $script:branch }
        if ((Test-Eq $dst 'main') -or (Test-Eq $dst 'master')) { $pairs.Add(@($src, $dst)) }
    }
    if ($script:cAll -or $mirror) {
        Add-ChangedBranch $pairs
    } elseif (-not $hasrefs) {
        if (Test-Eq (Get-LastLine (Get-CfgAll 'push.default')) 'matching') {
            Add-ChangedBranch $pairs
        } elseif (-not (Test-Eq $script:branch '')) {
            $d = $script:branch
            if (-not (Test-Eq $script:RPD '') -and (-not $remoteNamed -or (Test-Eq $script:remote $script:RR))) { $d = $script:RPD }
            if ((Test-Eq $d 'main') -or (Test-Eq $d 'master')) { $pairs.Add(@($script:branch, $d)) }
        }
    }
    if ($pairs.Count -eq 0) { exit 0 }

    foreach ($p in $pairs) {
        $src = $p[0]; $dst = $p[1]
        if (Test-Eq $src '') { continue }
        Test-Time
        if (-not (Test-Remote $script:remote)) {
            Resolve-PushTarget $dst
            Send-Deny 'git push' "The push names $($script:remote), which is not a configured remote. Use a configured remote name (git remote lists them)." $script:TGT
        }
        # an unborn HEAD (no commit): no source can be HEAD
        if ((Test-Eq $script:headsha '') -or (-not (Test-Eq $src 'HEAD') -and ((Test-Eq $script:branch '') -or -not (Test-Eq $src $script:branch)))) {
            Resolve-PushTarget $dst
            $unb = if (Test-Eq $script:headsha '') { ' (this branch has no commit yet)' } else { '' }
            Send-Deny 'git push' "The gate reviews the checked-out commit and the push source $src is not HEAD$unb. Check the source out first, then review and push." $script:TGT
        }
        $rsha = Invoke-Git $script:gdir @('rev-parse', '--verify', '--quiet', '--end-of-options', "refs/remotes/$($script:remote)/$dst")
        if ($null -eq $rsha) {
            Resolve-PushTarget $dst
            Send-Deny 'git push' "The remote-tracking ref $($script:remote)/$dst is unknown locally, so the commits to push cannot be counted. Run git fetch $($script:remote) $dst and retry; a push to a remote branch that does not yet exist needs AF_CODE_REVIEW_GATE=off in the launch environment." $script:TGT
        }
        if (Test-Eq $rsha $script:headsha) { continue }
        Resolve-PushTarget $dst
        Test-Marker 'git push' $script:TGT $dst 'push'
    }
    exit 0
}

# --- gh pr create|new / glab mr create|new <args> -----------------------------------
function Invoke-Pr([string]$Kind, [string[]]$A) {
    if (Test-Eq $Kind 'glab') {
        $label = 'glab mr create'
        $hl = '--source-branch'; $hs = '-s'; $bl = '--target-branch'; $bs = '-b'
        $vf = ' --title -t --description -d --assignee -a --label -l --milestone -m --reviewer --target-project --repo -R --head -H --related-issue -i '
    } else {
        $label = 'gh pr create'
        $hl = '--head'; $hs = '-H'; $bl = '--base'; $bs = '-B'
        $vf = ' --title -t --body -b --body-file -F --assignee -a --label -l --milestone -m --project -p --reviewer -r --template -T --repo -R --recover '
    }
    $src = ''; $dst = ''; $prDry = $false
    $i = 0; $prn = 0
    while ($i -lt $A.Count) {
        $t = $A[$i]; $i++
        $prn++
        if ($prn % 2000 -eq 0) { Test-Time }
        if (Test-Eq $t '--dry-run') { $prDry = $true; continue }
        if ((Test-Eq $t $hl) -or (Test-Eq $t $hs)) { $src = if ($i -lt $A.Count) { $A[$i] } else { '' }; if ($i -lt $A.Count) { $i++ }; continue }
        if ((Test-Eq $t $bl) -or (Test-Eq $t $bs)) { $dst = if ($i -lt $A.Count) { $A[$i] } else { '' }; if ($i -lt $A.Count) { $i++ }; continue }
        if (Test-StartsWith $t '--dry-run=') { Send-NotPlain }
        if (Test-StartsWith $t "$hl=") { $src = $t.Substring($hl.Length + 1); continue }
        if (Test-StartsWith $t "$bl=") { $dst = $t.Substring($bl.Length + 1); continue }
        # -x is one option; a longer single-dash word is a cluster or an attached value
        if (-not (Test-StartsWith $t '--') -and $t.Length -ge 3 -and [int]$t[0] -eq 45) { Send-NotPlain }
        if ($vf.Contains(' ' + $t + ' ', $script:Ord) -and $i -lt $A.Count) { $i++ }
    }
    if ($prDry) { exit 0 }
    Resolve-Loc $label
    if (-not (Initialize-Repo)) {
        if ($script:PREP_WT -ne 1) { Send-Deny $label $script:W_NOREPO "HEAD vs $(Get-OrDefault $dst 'its destination')" }
        # work tree without a commit: a repository with no refs at all denies W_NOREPO
        # (S.3-bis u, EDGE-007); with other refs no source can be HEAD (S.3-bis j)
        $nrRefs = Invoke-Git $script:gdir @('for-each-ref', '--count=1', '--format=x')
        if ($null -eq $nrRefs -or (Test-Eq $nrRefs '')) { Send-Deny $label $script:W_NOREPO "HEAD vs $(Get-OrDefault $dst 'its destination')" }
        if (Test-Eq $dst '') { Resolve-PrDefaultDst; $dst = $script:PDD }
        $ub = Invoke-Git $script:gdir @('symbolic-ref', '--short', '--quiet', 'HEAD')
        if ($null -eq $ub) { $ub = '' }
        Send-Deny $label "The gate reviews the checked-out commit and the source $(Get-OrDefault $src 'HEAD') is not HEAD (this branch has no commit yet). Check the source out first, then review and open the request." "$(Get-OrDefault $ub 'HEAD') vs $dst"
    }
    if (Test-Eq $dst '') { Resolve-PrDefaultDst; $dst = $script:PDD }
    Resolve-Chain; $script:remote = $script:RR
    $tgt = "$(Get-OrDefault $script:branch 'HEAD') vs $dst"
    if (-not (Test-Eq $src '') -and -not (Test-Eq $src 'HEAD') -and ((Test-Eq $script:branch '') -or -not (Test-Eq $src $script:branch))) {
        Send-Deny $label "The gate reviews the checked-out commit and the source $src is not HEAD. Check the source out first, then review and open the request." $tgt
    }
    Test-Marker $label $tgt $dst 'pr'
    exit 0
}

try {
    $ErrorActionPreference = 'Stop'

    $gateEnv = $env:AF_CODE_REVIEW_GATE
    if ($gateEnv) {
        if (Test-Eq $gateEnv.Trim(" `t`r`n`f`v").ToLowerInvariant() 'off') { exit 0 }
    }

    $reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false))
    $payload = $reader.ReadToEnd()
    if (-not $payload) { exit 0 }

    $doc = [System.Text.Json.JsonDocument]::Parse($payload)
    $root = $doc.RootElement
    $JK = [System.Text.Json.JsonValueKind]
    if ($root.ValueKind -ne $JK::Object) { exit 0 }
    $ti = $null; $sid = ''; $cwd0 = ''; $tool = ''
    foreach ($p in $root.EnumerateObject()) {
        # ordinal key match (PowerShell's switch and -ceq compare culture-aware)
        $sv = if ($p.Value.ValueKind -eq $JK::String) { $p.Value.GetString() } else { '' }
        if (Test-Eq $p.Name 'tool_input') { $ti = $p.Value }
        elseif (Test-Eq $p.Name 'session_id') { $sid = $sv }
        elseif (Test-Eq $p.Name 'cwd') { $cwd0 = $sv }
        elseif (Test-Eq $p.Name 'tool_name') { $tool = $sv }
    }
    if ($null -eq $ti -or $ti.ValueKind -ne $JK::Object) { exit 0 }
    $cmdEl = $null
    foreach ($p in $ti.EnumerateObject()) { if (Test-Eq $p.Name 'command') { $cmdEl = $p.Value } }
    if ($null -eq $cmdEl -or $cmdEl.ValueKind -ne $JK::String) { exit 0 }
    $cmd = $cmdEl.GetString().Replace([string][char]0, '').TrimEnd("`n")
    if (Test-Eq $cmd '') { exit 0 }

    # --- candidate test (S.1), on the command's UTF-8 bytes (awk under LC_ALL=C)
    $bstr = [System.Text.Encoding]::Latin1.GetString([System.Text.Encoding]::UTF8.GetBytes($cmd))
    $big = ($bstr.Length -gt 65536)
    # the session id is sanitised before the candidate and size tests
    $sid = [regex]::Replace($sid, '[^A-Za-z0-9_-]', '')
    if (Test-Eq $sid '') { exit 0 }
    $fp = [regex]::Replace($bstr, '[\\`]\r?\n', '')
    $fp = $fp.Replace("`r`n", "`n")
    foreach ($ck in 152..158) { $fp = $fp.Replace([string]::new([char[]]@([char]226, [char]128, [char]$ck)), '') }
    $fp = [regex]::Replace($fp, '\$["'']', '')
    $t1 = Get-WithoutBraceExpansion $fp
    $t1 = [regex]::Replace($t1, '["''\\`]', '')
    $t2 = $fp.Replace('${', '').Replace('}', '')
    $t2 = [regex]::Replace($t2, '["''\\`]', '')
    if (-not ((Test-Cand $t1) -or (Test-Cand $t2))) { exit 0 }
    if ($big) { Send-Deny $script:K_ANY $script:W_SIZE $script:T_ANY }

    $tool = $tool.Replace("`r", '').Replace("`n", '')
    $dialectPs = ((Test-Eq $tool 'PowerShell') -or (Test-Eq $tool 'powershell') -or (Test-Eq $tool 'POWERSHELL'))
    $script:dialectPs = $dialectPs

    $cwd0 = $cwd0.Replace("`r", '').Replace("`n", '')
    if (-not (Test-Eq $cwd0 '') -and -not [System.IO.Directory]::Exists($cwd0)) {
        $cm = Convert-MsysPath $cwd0
        if ($null -ne $cm -and [System.IO.Directory]::Exists($cm)) { $cwd0 = $cm }
    }
    if ((Test-Eq $cwd0 '') -or -not [System.IO.Directory]::Exists($cwd0)) { $cwd0 = (Get-Location).ProviderPath }
    $script:cwd0 = $cwd0

    $stateRoot = $env:CLAUDE_STATE_DIR
    if (-not $stateRoot) { $stateRoot = Join-Path $HOME '.claude/.state' }
    $script:marker = "$stateRoot/code-review/$sid"

    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { $null = $_ }

    # --- plain-form tokenizer (S.2)
    $tcmd = $cmd
    if ($dialectPs) {
        foreach ($cq in @(0x2018, 0x2019, 0x201A, 0x201B)) { $tcmd = $tcmd.Replace([string][char]$cq, "'") }
        foreach ($cq in @(0x201C, 0x201D, 0x201E)) { $tcmd = $tcmd.Replace([string][char]$cq, '"') }
    }
    $tok = [GateTok]::new()
    if (-not $tok.Scan([System.Text.Encoding]::Latin1.GetString([System.Text.Encoding]::UTF8.GetBytes($tcmd)), $dialectPs)) { Send-NotPlain }
    $T = [System.Collections.Generic.List[string]]::new()
    foreach ($x in $tok.Out) { $T.Add([System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::Latin1.GetBytes($x))) }
    if ($T.Count -eq 0) { Send-NotPlain }

    # --- grammar: one optional location prefix, then one command
    $lp = 0
    if (Test-Eq $T[0] 'Wcd') { $lp = 1 }
    elseif ($dialectPs -and [regex]::IsMatch($T[0], '^W[Cc][Dd]\z')) { $lp = 1 }
    elseif ($dialectPs -and [regex]::IsMatch($T[0], '^W[Ss][Ee][Tt]-[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]\z')) { $lp = 2 }
    if ($lp -ne 0) {
        if ($T.Count -lt 3) { Send-NotPlain }
        if (-not (Test-StartsWith $T[1] 'W') -or $T[1].Length -lt 2) { Send-NotPlain }
        $script:loc = $T[1].Substring(1)
        if (Test-Eq $T[2] 'O&&') { if ($lp -ne 1) { Send-NotPlain } }
        elseif (-not (Test-Eq $T[2] 'O;')) { Send-NotPlain }
        $script:hasLoc = $true
        $T.RemoveRange(0, 3)
    }
    if ($T.Count -lt 1) { Send-NotPlain }
    foreach ($x in $T) { if (Test-StartsWith $x 'O') { Send-NotPlain } }

    $kind = ''
    $rest = $null
    if (Test-Eq $T[0] 'Wgit') {
        $j = 1
        if ($j -lt $T.Count -and (Test-Eq $T[$j] 'W-C') -and -not $script:hasLoc) {
            if ($T.Count - $j -lt 2) { Send-NotPlain }
            $script:loc = $T[$j + 1].Substring(1); $script:hasLoc = $true; $j += 2
        }
        if (-not ($j -lt $T.Count -and (Test-Eq $T[$j] 'Wpush'))) { Send-NotPlain }
        $kind = 'push'; $rest = $T.GetRange($j + 1, $T.Count - $j - 1)
    } elseif ((Test-Eq $T[0] 'Wgh') -or (Test-Eq $T[0] 'Wglab')) {
        $sub = if (Test-Eq $T[0] 'Wgh') { 'Wpr' } else { 'Wmr' }
        if (-not ($T.Count -ge 2 -and (Test-Eq $T[1] $sub))) { Send-NotPlain }
        if (-not ($T.Count -ge 3 -and ((Test-Eq $T[2] 'Wcreate') -or (Test-Eq $T[2] 'Wnew')))) { Send-NotPlain }
        $kind = $T[0].Substring(1); $rest = $T.GetRange(3, $T.Count - 3)
    } else { Send-NotPlain }
    if ($script:hasLoc) {
        $lc = $script:loc
        if (Test-Eq $lc '') { Send-NotPlain }
        # drive-relative (C:, C:repo) and root-relative (\repo) directories are not plain
        if ($lc -match '^[A-Za-z]:([^/\\]|\z)' -or $lc -match '^\\([^\\/]|\z)') { Send-NotPlain }
        # option-looking and UNC/network directories are decided before any filesystem
        # access; ~user is not plain (a bare ~ and ~/... stay)
        if ((Test-StartsWith $lc '-') -or (Test-StartsWith $lc '//') -or (Test-StartsWith $lc '\\') -or (Test-StartsWith $lc '/\') -or (Test-StartsWith $lc '\/') -or (Test-StartsWith $lc ([string][char]2))) { Send-NotPlain }
        if ((Test-StartsWith $lc '~') -and -not ((Test-Eq $lc '~') -or (Test-StartsWith $lc '~/') -or (Test-StartsWith $lc '~\'))) { Send-NotPlain }
        # the MSYS drive form /c/... is Bash-dialect only (S.3-bis m)
        if ($dialectPs -and (Test-StartsWith $lc '/')) { Send-NotPlain }
    }
    $tn = 0
    foreach ($x in $rest) { $tn++; if ($tn % 2000 -eq 0) { Test-Time } }
    Test-Time
    $args2 = [string[]]@($rest | ForEach-Object { $_.Substring(1) })

    if (Test-Eq $kind 'push') { Invoke-Push $args2 } else { Invoke-Pr $kind $args2 }
    exit 0
} catch {
    exit 0
}
