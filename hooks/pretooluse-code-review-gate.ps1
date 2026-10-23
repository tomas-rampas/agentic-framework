#Requires -Version 7.0
# pretooluse-code-review-gate.ps1 - blocking PreToolUse hook (matcher: Bash|PowerShell).
#
# PowerShell twin of pretooluse-code-review-gate.sh; the grammar block is shared byte for
# byte; the .ps1 is the reference for decision T. The two must produce byte-identical deny output.
#
# Denies a shell command that opens a pull/merge request (gh pr create|new,
# glab mr create|new) or pushes to main/master (git push, force included)
# unless a code-review-gatekeeper sub-agent has recorded VERDICT: APPROVED for
# the exact commit (HEAD) against the exact destination, with a reviewed range
# (<merge-base>..<head-sha>) that binds the approval to the commits being sent,
# in the marker <state>/code-review/<session_id> written by record-subagent-run
# (read here, never written). Grammar: decisions S and T of specs/code-review-gate.md
# (a whitelist of plain forms written as one regex grammar); the unlock rule is
# REQ-004. State dir: CLAUDE_STATE_DIR, else $HOME/.claude/.state.
#
# SECURITY: the command string is untrusted data. It is NEVER evaluated or
# executed: no Invoke-Expression, no call operator on any part of it, no
# cmd /c. The gate does not try to understand shell text. Three regex stages,
# each a fixed number of passes over the command's UTF-8 bytes (one char per
# byte), no loop over characters or tokens; every regex has CultureInvariant
# and a match timeout equal to the remaining 8 s budget, and a timeout denies W_TIME:
#  1. (S.1, T.2) candidate test: continuations joined, curly quotes and a $
#     before a quote removed, then three spellings (${...} removed; ${ and }
#     removed; ${NAME} and ${NAME<op> removed, then }), each without quotes,
#     backslashes and backticks, the anchored git stash push exempted; then the
#     words git+push or gh/glab+pr/mr+create/new (git, gh and glab
#     case-insensitive). Anything else exits 0 with no git call (fast path).
#     Over 64 KB (bytes) the same test decides: match denies (W_SIZE), else exit 0.
#  2. (FORM, T.3) the text, with CR and LF as SOH and SOH as STX (PowerShell
#     dialect: curly quotes mapped to ASCII quotes first), must be one plain form
#     of the grammar block below (B_FORM for Bash, P_FORM for PowerShell):
#     [cd <dir> && | cd <dir>; | Set-Location <dir>;]
#     git [-C <dir>] push [words] [redirections], or gh pr create|new ... /
#     glab mr create|new ...; a word is literal (bare bytes and clean quoted
#     strings). Every other candidate is denied W_PLAIN (S.3).
#  3. (token stage, T.4) a lexer pass and fixed passes make W/O tokens; STRUCT
#     reads kind, joiner or -C and directory; PUSHARG (push allowlist) and
#     PR1/PR2 (gh/glab options, the last --head/--base wins) read the values left
#     to right; an unread - word, a third positional or an empty word is not plain.
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
# internal error outside the grammar stages. A bare repository or a directory
# inside .git is denied W_LOC.
# Not fail-open: a non-plain candidate (W_PLAIN, also any error in the FORM or
# token stage), a cd/-C directory that is missing or not a git work tree (W_LOC),
# a pull/merge request from a directory that is not a git work tree (W_NOREPO).

$script:SW = [System.Diagnostics.Stopwatch]::StartNew()

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

# --- grammar (decision T) -----------------------------------------------------------
# The block below is shared byte for byte with the .sh. Each line is NAME=TEXT; {NAME}
# refers to an earlier line and is expanded once per run by literal replacement. The
# placeholders <TAB> <BS> <HI> <CURLY> <Q> and the marker names are the only
# per-engine difference (Resolve-GrammarText). {X_CD}, {X_VF}, {HL}, {HS}, {BL}, {BS}
# select the dialect or the tool and are filled in where the pattern is used.
$script:GDEFS = @'
# --- S.1 candidate test (on the S.1 text)
S1_JOIN=[\\`]<CR>?<SOH>
S1_CURLY=<CURLY>
S1_DQ=\$["<Q>]
S1_BRACE1=\$\{[^}]*(\}|$)
S1_BRACE2O=\$\{
S1_BRACE2C=\}
S1_BRACE3V=\$\{[A-Z_a-z][0-9A-Z_a-z]*\}
S1_BRACE3O=\$\{[A-Z_a-z][0-9A-Z_a-z]*:?[+=?-]
S1_QUOTES=["<Q>\\`]
S1_STASH=^([ <TAB><CR><SOH>]*git[^A-Za-z0-9]+stash[^A-Za-z0-9]+)push
W_GIT=(^|[^A-Za-z0-9])[Gg][Ii][Tt]([^A-Za-z0-9]|$)
W_PUSH=(^|[^A-Za-z0-9])push([^A-Za-z0-9.]|$)
W_GH=(^|[^A-Za-z0-9])([Gg][Hh]|[Gg][Ll][Aa][Bb])([^A-Za-z0-9]|$)
W_PRMR=(^|[^A-Za-z0-9])(pr|mr)([^A-Za-z0-9]|$)
W_CRNEW=(^|[^A-Za-z0-9])(create|new)([^A-Za-z0-9]|$)
# --- plain-form language (S.2)
B_B=[]!%+-:=@-Z^_a-z~<HI>]
P_B=[]!%+.-:=@-Z<BS>^_a-z~-]
P_B1=[]!%+.-:=A-Z<BS>^_a-z~-]
SQC=[][ <TAB>!-#%&(-Z^_a-~<HI>]
DQC=[][ <TAB>!#%-Z^_a-~<HI>]
SQXB=[]<TAB> !"%+-:=>@-Z^_a-z~<HI>]
SQXBS=[]<TAB> !"%+-:=>@-Z<BS>^_a-z~<HI>]
SQXP=[]<TAB> !"%+-:=>@-Z^_a-z~]
SQXPS=[]<TAB> !"%+-:=>@-Z<BS>^_a-z~]
DQXP=[]<TAB> !%<Q>+-:=>@-Z^_a-z~]
DQXPS=[]<TAB> !%<Q>+-:=>@-Z<BS>^_a-z~]
B_SQ=<Q>({SQC}*|{SQXB}*\\{SQXBS}*)<Q>
B_DQ="{DQC}*"
B_W=({B_B}|{B_SQ}|{B_DQ})+
P_SQ=<Q>({SQC}*|{SQXP}*\\{SQXPS}*)<Q>
P_DQ="({DQC}*|{DQXP}*\\{DQXPS}*)"
P_Q=({P_SQ}|{P_DQ})
P_W=(@|{P_Q}|{P_B1}{P_B}*({P_Q}{P_B}+)*{P_Q}?)
B_RD=[0-9]?>>?(&[0-9]|[ <TAB>]*{B_B}+)
P_RD=[0-9*]?>>?(&[0-9]|[ <TAB>]*{P_B}+)
B_LOC=cd[ <TAB>]+{B_W}[ <TAB>]*(&&|;)[ <TAB>]*
P_LOC=([Cc][Dd][ <TAB>]+{P_W}[ <TAB>]*(&&|;)|[Ss][Ee][Tt]-[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn][ <TAB>]+{P_W}[ <TAB>]*;)[ <TAB>]*
B_FORM=^[ <TAB><SOH>]*(({B_LOC})?(gh[ <TAB>]+pr|glab[ <TAB>]+mr)[ <TAB>]+(create|new)|({B_LOC}git|git([ <TAB>]+-C[ <TAB>]+{B_W})?)[ <TAB>]+push)([ <TAB>]+{B_W})*([ <TAB>]+{B_RD})*[ <TAB><SOH>]*$
P_FORM=^[ <TAB><SOH>]*(({P_LOC})?(gh[ <TAB>]+pr|glab[ <TAB>]+mr)[ <TAB>]+(create|new)|({P_LOC}git|git([ <TAB>]+-C[ <TAB>]+{P_W})?)[ <TAB>]+push)([ <TAB>]+{P_W})*([ <TAB>]+{P_RD})*[ <TAB><SOH>]*$
TILDE=^[ <TAB><SOH>]*(cd|git[ <TAB>]+-C)[ <TAB>]+~(/|[ <TAB>;&])
# --- token stage
LEX=[ <TAB>]*(&&|;)[ <TAB>]*|[ <TAB>]+([0-9*]?>>?(&[0-9])?)|([ <TAB><SOH>]+)|<Q>([^<Q>]*)<Q>|"([^"]*)"
T=<L>W([^<R>]*)<R>
B_CD=cd
P_CD=([Cc][Dd]|[Ss][Ee][Tt]-[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn])
STRUCT=^(<L>W{X_CD}<R>{T}<L>O([^<R>]*)<R>)?<L>W(git|gh|glab)<R>(<L>W(-C)<R>{T})?<L>W(push|pr|mr)<R>(<L>W(create|new)<R>)?
PUSHOPT=-u|--set-upstream|-f|--force|--force-with-lease|--follow-tags|--no-verify|-q|--quiet|-v|--verbose|--porcelain
PUSHARG=<L>W-o<R>{T}|<L>W--(push-option|force-with-lease)=([^<R>]*)<R>|<L>W({PUSHOPT})<R>|<L>W(--tags|-n|--dry-run|-d|--delete)<R>
ALPHA=[%+-:=@-Z_a-z]
GH_VF=--title|-t|--body|-b|--body-file|-F|--assignee|-a|--label|-l|--milestone|-m|--project|-p|--reviewer|-r|--template|-T|--repo|-R|--recover
GL_VF=--title|-t|--description|-d|--assignee|-a|--label|-l|--milestone|-m|--reviewer|--target-project|--repo|-R|--head|-H|--related-issue|-i
PR1=<L>W({HL}|{HS})<R>({T})?|<L>W({BL}|{BS})<R>({T})?|<L>W({X_VF})<R>(<L>W[^<R>]*<R>)?
PR2=<L>W({HL})=([^<R>]*)<R>|<L>W({BL})=([^<R>]*)<R>|<L>W(--dry-run)<R>|<L>W(--dry-run=[^<R>]*|-[^-<R>][^<R>]+)<R>
'@

# Markers: control chars the stages guarantee absent from the text they run on (FORM
# admits no control char but tab, and SOH only as leading or trailing white space).
$script:MK = @{
    SOH = [string][char]0x01; STX = [string][char]0x02
    A = [string][char]0x11; B = [string][char]0x12; C = [string][char]0x13; D = [string][char]0x14; E = [string][char]0x15
    L = [string][char]0x16; R = [string][char]0x17
    V = [string][char]0x18; VE = [string][char]0x19; F = [string][char]0x1A; FE = [string][char]0x1B
    S = [string][char]0x1C; SV = [string][char]0x1D; SE = [string][char]0x1E
    DD = [string][char]0x0D; DV = [string][char]0x0E; DE = [string][char]0x0F
    N = [string][char]0x10; NE = [string][char]0x0B; X = [string][char]0x0C; XE = [string][char]0x08
}

# The .NET spelling of the placeholders (one char per byte: the text is a Latin1 view
# of the command's UTF-8 bytes).
function Resolve-GrammarText([string]$V) {
    return $V.Replace('<TAB>', '\t').Replace('<BS>', '\\').Replace('<HI>', '\x80-\xFF').Replace('<CURLY>', '\xE2\x80[\x98-\x9E]').Replace('<Q>', "'").Replace('<CR>', '\x0D').Replace('<SOH>', '\x01').Replace('<STX>', '\x02').Replace('<ETX>', '\x03').Replace('<L>', '\x16').Replace('<R>', '\x17')
}

# Expand-Grammar: NAME -> .NET pattern, {NAME} references expanded in block order by
# literal replacement; a {NAME} that is not a block line (a selector) is kept as is.
# -S1 keeps only the S.1 lines (S1_*, W_*, which refer to no other line): the hot path.
function Expand-Grammar([switch]$S1) {
    $defs = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $ev = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $k = $m.Groups[1].Value
        if ($defs.ContainsKey($k)) { return $defs[$k] }
        return $m.Value
    }
    foreach ($ln in $script:GDEFS.Split("`n")) {
        $ln = $ln.TrimEnd("`r")
        if ($ln.Length -eq 0 -or $ln.StartsWith('#', $script:Ord)) { continue }
        $eq = $ln.IndexOf([char]'=')
        if ($S1 -and -not ($ln.StartsWith('S1_', $script:Ord) -or $ln.StartsWith('W_', $script:Ord))) { continue }
        $v = $ln.Substring($eq + 1)
        if ($v.IndexOf([char]'{') -ge 0) { $v = [regex]::Replace($v, '\{([A-Z][A-Z0-9_]*)\}', $ev) }
        $defs[$ln.Substring(0, $eq)] = $v
    }
    $out = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($k in $defs.Keys) { $out[$k] = Resolve-GrammarText $defs[$k] }
    return $out
}

# A grammar regex: CultureInvariant, match timeout = the remaining 8 s budget (>= 100 ms).
function Get-GateRx([string]$P) {
    $ms = [math]::Max(100.0, 8000.0 - $script:SW.Elapsed.TotalMilliseconds)
    return [regex]::new($P, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromMilliseconds($ms))
}

function Test-RegexTimeout($Err) {
    $e = $Err.Exception
    while ($null -ne $e) {
        if ($e -is [System.Text.RegularExpressions.RegexMatchTimeoutException]) { return $true }
        $e = $e.InnerException
    }
    return $false
}

# Test-Spelling: one S.1 spelling holds (git and push) or (gh/glab and pr/mr and create/new).
function Test-Spelling([string]$T) {
    $g = $script:G
    if ((Get-GateRx $g['W_GIT']).IsMatch($T) -and (Get-GateRx $g['W_PUSH']).IsMatch($T)) { return $true }
    return ((Get-GateRx $g['W_GH']).IsMatch($T) -and (Get-GateRx $g['W_PRMR']).IsMatch($T) -and (Get-GateRx $g['W_CRNEW']).IsMatch($T))
}

# Test-Candidate (S.1, T.2) on the command's bytes as chars. A regex timeout denies
# W_TIME; any other error keeps S.1's rule (over the cap W_SIZE, else exit 0).
function Test-Candidate([string]$Bytes, [bool]$Big) {
    try {
        $script:G = Expand-Grammar -S1
        $g = $script:G; $mk = $script:MK
        $s = $Bytes.Replace($mk.SOH, $mk.STX).Replace([string][char]3, $mk.STX).Replace("`n", $mk.SOH)
        $s = (Get-GateRx $g['S1_JOIN']).Replace($s, '')
        $s = (Get-GateRx $g['S1_CURLY']).Replace($s, '')
        $s = (Get-GateRx $g['S1_DQ']).Replace($s, '')
        $rq = Get-GateRx $g['S1_QUOTES']; $rs = Get-GateRx $g['S1_STASH']; $rc = Get-GateRx $g['S1_BRACE2C']
        $t1 = (Get-GateRx $g['S1_BRACE1']).Replace($s, '')
        $t1 = $rs.Replace($rq.Replace($t1, ''), '${1}PUSH', 1)
        if (Test-Spelling $t1) { return $true }
        $t2 = $rc.Replace((Get-GateRx $g['S1_BRACE2O']).Replace($s, ''), '')
        $t2 = $rs.Replace($rq.Replace($t2, ''), '${1}PUSH', 1)
        if (Test-Spelling $t2) { return $true }
        $t3 = (Get-GateRx $g['S1_BRACE3O']).Replace((Get-GateRx $g['S1_BRACE3V']).Replace($s, ''), '')
        $t3 = $rs.Replace($rq.Replace($rc.Replace($t3, ''), ''), '${1}PUSH', 1)
        return (Test-Spelling $t3)
    } catch {
        if (Test-RegexTimeout $_) { Send-Deny $script:K_ANY $script:W_TIME $script:T_ANY }
        if ($Big) { Send-Deny $script:K_ANY $script:W_SIZE $script:T_ANY }
        exit 0
    }
}

function ConvertFrom-ByteText([string]$S) { return [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::Latin1.GetBytes($S)) }

# Get-PlainField (FORM, T.3; token stage, T.4) on the tokenizer text (PowerShell
# dialect: curly quotes already mapped). Returns @{ Kind; Op; Loc; Flags; A1; A2 }
# (A1 A2 = remote and refspec, or source and destination); a text that is not plain,
# and any error here, denies W_PLAIN; a regex timeout denies W_TIME.
function Get-PlainField([string]$Text, [bool]$Psd) {
    try {
        $script:G = Expand-Grammar
        $g = $script:G; $mk = $script:MK
        $L = $mk.L; $R = $mk.R
        $b = [System.Text.Encoding]::Latin1.GetString([System.Text.Encoding]::UTF8.GetBytes($Text))
        $b = $b.Replace($mk.SOH, $mk.STX).Replace("`r", $mk.SOH).Replace("`n", $mk.SOH)
        if (-not (Get-GateRx $g[$(if ($Psd) { 'P_FORM' } else { 'B_FORM' })]).IsMatch($b)) { Send-NotPlain }

        # lexer: joiner, redirection operator, blank run, quoted strings; then W/O tokens
        $t = (Get-GateRx $g['LEX']).Replace($b, $mk.A + '${1}' + $mk.B + '${4}' + $mk.C + '${5}${6}' + $mk.D + '${2}' + $mk.E)
        $t = (Get-GateRx '\x11\x12\x13\x14[0-9*]?>[^\x02]*$').Replace($t, '')
        $t = (Get-GateRx '\x11(&&|;)\x12\x13\x14\x15').Replace($t, $R + $L + 'O${1}' + $R + $L + 'W')
        $t = (Get-GateRx '\x11\x12[ \t\x01]+\x13\x14\x15').Replace($t, $R + $L + 'W')
        # leading and trailing blank runs go before the quote markers do, so a trailing
        # empty quoted word ("") stays an (empty) token
        $t = (Get-GateRx '^\x17\x16W|\x17\x16W$').Replace($t, '')
        $t = $t.Replace($mk.A + $mk.B + $mk.C, '').Replace($mk.D + $mk.E, '')
        $t = $L + 'W' + $t + $R

        # header: location prefix, kind, -C; P_CD holds one group, so the groups shift by one
        $cd = if ($Psd) { $g['P_CD'] } else { $g['B_CD'] }
        $m = (Get-GateRx $g['STRUCT'].Replace('{X_CD}', $cd)).Match($t)
        if (-not $m.Success) { Send-NotPlain }
        $o = if ($Psd) { 1 } else { 0 }
        $kind = $m.Groups[4 + $o].Value; $sub = $m.Groups[8 + $o].Value
        $op = ''; $loc = ''
        if ($m.Groups[1].Success -and $m.Groups[5 + $o].Success) { Send-NotPlain }
        if ($m.Groups[1].Success) { $loc = $m.Groups[2 + $o].Value; $op = $m.Groups[3 + $o].Value }
        elseif ($m.Groups[5 + $o].Success) { $loc = $m.Groups[7 + $o].Value; $op = '-C' }
        if ([string]::Equals($kind, 'git')) {
            # git push never takes create/new into its header: the rest starts after push
            if (-not [string]::Equals($sub, 'push')) { Send-NotPlain }
            $r = $t.Substring($m.Groups[8 + $o].Index + $m.Groups[8 + $o].Length + 1)
        } else {
            $want = if ([string]::Equals($kind, 'gh')) { 'pr' } else { 'mr' }
            if (-not [string]::Equals($sub, $want) -or -not $m.Groups[9 + $o].Success) { Send-NotPlain }
            $r = $t.Substring($m.Index + $m.Length)
        }
        if ($r.Contains($L + 'O')) { Send-NotPlain }
        if (-not $Psd -and $loc.StartsWith('~', $script:Ord) -and -not (Get-GateRx $g['TILDE']).IsMatch($b)) { Send-NotPlain }
        $flags = ''; $a1 = ''; $a2 = ''

        if ([string]::Equals($kind, 'git')) {
            # PUSHARG: -o and its value, --push-option= / --force-with-lease= values, no-op options, flags
            $r = (Get-GateRx $g['PUSHARG']).Replace($r, $mk.V + '${1}${3}' + $mk.VE + $mk.F + '${5}' + $mk.FE)
            # PowerShell: an option value is held to the push alphabet (S.3-bis c)
            if ($Psd -and (Get-GateRx ('\x18' + $g['ALPHA'] + '*[^%+-:=@-Z_a-z\x19]')).IsMatch($r)) { Send-NotPlain }
            if ((Get-GateRx '\x1A(-n|--dry-run)\x1B').IsMatch($r)) { $flags += 'N' }
            if ((Get-GateRx '\x1A(-d|--delete)\x1B').IsMatch($r)) { $flags += 'D' }
            if ((Get-GateRx '\x1A--tags\x1B').IsMatch($r)) { $flags += 'T' }
            $r = (Get-GateRx '\x18[^\x19]*\x19\x1A[^\x1B]*\x1B').Replace($r, '')
            # an unread - word, an empty word, a third positional
            if ((Get-GateRx ('\x16W-|\x16W\x17|' + $g['T'] + $g['T'] + '\x16')).IsMatch($r)) { Send-NotPlain }
            $pm = (Get-GateRx ('^(' + $g['T'] + ')?(' + $g['T'] + ')?$')).Match($r)
            if (-not $pm.Success) { Send-NotPlain }
            $a1 = $pm.Groups[2].Value; $a2 = $pm.Groups[4].Value
        } else {
            if ([string]::Equals($kind, 'glab')) {
                $hl = '--source-branch'; $hs = '-s'; $bl = '--target-branch'; $bs = '-b'; $vf = $g['GL_VF']
            } else {
                $hl = '--head'; $hs = '-H'; $bl = '--base'; $bs = '-B'; $vf = $g['GH_VF']
            }
            $p1 = $g['PR1'].Replace('{HL}', $hl).Replace('{HS}', $hs).Replace('{BL}', $bl).Replace('{BS}', $bs).Replace('{X_VF}', $vf)
            $p2 = $g['PR2'].Replace('{HL}', $hl).Replace('{BL}', $bl)
            # value-taking options consume the next word first, then the single-word rules
            $r = (Get-GateRx $p1).Replace($r, $mk.S + '${1}' + $mk.SV + '${3}' + $mk.SE + $mk.DD + '${4}' + $mk.DV + '${6}' + $mk.DE)
            $r = (Get-GateRx $p2).Replace($r, $mk.S + '${1}' + $mk.SV + '${2}' + $mk.SE + $mk.DD + '${3}' + $mk.DV + '${4}' + $mk.DE + $mk.N + '${5}' + $mk.NE + $mk.X + '${6}' + $mk.XE)
            $r = $r.Replace($mk.S + $mk.SV + $mk.SE, '').Replace($mk.DD + $mk.DV + $mk.DE, '').Replace($mk.N + $mk.NE, '').Replace($mk.X + $mk.XE, '')
            if ((Get-GateRx '\x0C[^\x08]+\x08').IsMatch($r)) { Send-NotPlain }
            if ((Get-GateRx '\x10--dry-run\x0B').IsMatch($r)) { $flags += 'N' }
            # the last --head / --base wins: one anchored match each
            $a1 = (Get-GateRx '^([^\x03]*\x1C[^\x1D]*\x1D([^\x1E]*)\x1E)?[^\x1C]*$').Match($r).Groups[2].Value
            $a2 = (Get-GateRx '^([^\x03]*\x0D[^\x0E]*\x0E([^\x0F]*)\x0F)?[^\x0D]*$').Match($r).Groups[2].Value
        }
        return @{ Kind = $kind; Op = $op; Loc = (ConvertFrom-ByteText $loc); Flags = $flags; A1 = (ConvertFrom-ByteText $a1); A2 = (ConvertFrom-ByteText $a2) }
    } catch {
        if (Test-RegexTimeout $_) { Send-Deny $script:K_ANY $script:W_TIME $script:T_ANY }
        Send-NotPlain
    }
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

# --- git push (S.2 option allowlist read by the token stage, S.4 decision) ----------
# $Remote, $Refs: the positionals; $Flags: N dry run, D delete, T --tags.
function Invoke-Push([string]$Remote, [string]$Refs, [string]$Flags) {
    $dry = $Flags.Contains('N'); $del = $Flags.Contains('D'); $tags = $Flags.Contains('T'); $mirror = $false
    $script:remote = $Remote; $refs = $Refs
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

# --- gh pr create|new / glab mr create|new ------------------------------------------
# $Src, $Dst: the last --head / --base (--source-branch / --target-branch) values;
# $Flags: N --dry-run.
function Invoke-Pr([string]$Kind, [string]$Src, [string]$Dst, [string]$Flags) {
    $label = if (Test-Eq $Kind 'glab') { 'glab mr create' } else { 'gh pr create' }
    $src = $Src; $dst = $Dst; $prDry = $Flags.Contains('N')
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

    # --- candidate test (S.1, T.2), on the command's UTF-8 bytes (one char per byte)
    $bstr = [System.Text.Encoding]::Latin1.GetString([System.Text.Encoding]::UTF8.GetBytes($cmd))
    $big = ($bstr.Length -gt 65536)
    # the session id is sanitised before the candidate and size tests
    $sid = [regex]::Replace($sid, '[^A-Za-z0-9_-]', '')
    if (Test-Eq $sid '') { exit 0 }
    # every keyword holds g or G, and no S.1 deletion adds one
    if ($bstr.IndexOfAny([char[]]@('g', 'G')) -lt 0) { exit 0 }
    if (-not (Test-Candidate $bstr $big)) { exit 0 }
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

    # --- FORM and token stage (T.3, T.4)
    $tcmd = $cmd
    if ($dialectPs) {
        foreach ($cq in @(0x2018, 0x2019, 0x201A, 0x201B)) { $tcmd = $tcmd.Replace([string][char]$cq, "'") }
        foreach ($cq in @(0x201C, 0x201D, 0x201E)) { $tcmd = $tcmd.Replace([string][char]$cq, '"') }
    }
    $pf = Get-PlainField $tcmd $dialectPs
    $kind = $pf.Kind
    $script:loc = $pf.Loc; $script:hasLoc = -not (Test-Eq $pf.Op '')

    # --- post-checks on the location (T.5)
    if ($script:hasLoc) {
        $lc = $script:loc
        if (Test-Eq $lc '') { Send-NotPlain }
        # drive-relative (C:, C:repo) and root-relative (\repo) directories are not plain
        if ($lc -match '^[A-Za-z]:([^/\\]|\z)' -or $lc -match '^\\([^\\/]|\z)') { Send-NotPlain }
        # option-looking and UNC/network directories are decided before any filesystem
        # access; ~user is not plain (a bare ~ and ~/... stay)
        if ((Test-StartsWith $lc '-') -or (Test-StartsWith $lc '//') -or (Test-StartsWith $lc '\\') -or (Test-StartsWith $lc '/\') -or (Test-StartsWith $lc '\/')) { Send-NotPlain }
        if ((Test-StartsWith $lc '~') -and -not ((Test-Eq $lc '~') -or (Test-StartsWith $lc '~/') -or (Test-StartsWith $lc '~\'))) { Send-NotPlain }
        # the MSYS drive form /c/... is Bash-dialect only (S.3-bis m)
        if ($dialectPs -and (Test-StartsWith $lc '/')) { Send-NotPlain }
    }
    Test-Time

    if (Test-Eq $kind 'git') { Invoke-Push $pf.A1 $pf.A2 $pf.Flags } else { Invoke-Pr $kind $pf.A1 $pf.A2 $pf.Flags }
    exit 0
} catch {
    exit 0
}
