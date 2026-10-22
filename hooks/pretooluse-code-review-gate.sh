#!/bin/sh
set -u
# pretooluse-code-review-gate.sh - blocking PreToolUse hook (matcher: Bash|PowerShell).
#
# Denies a shell command that opens a pull/merge request (gh pr create|new,
# glab mr create|new) or pushes to main/master (git push, force included)
# unless a code-review-gatekeeper sub-agent has recorded VERDICT: APPROVED for
# the exact commit (HEAD) against the exact destination, with a reviewed range
# (<merge-base>..<head-sha>) that binds the approval to the commits being sent,
# in the marker <state>/code-review/<session_id> written by record-subagent-run.
# Grammar: decision S of specs/code-review-gate.md (a whitelist of plain forms);
# the unlock rule is REQ-004. State dir: CLAUDE_STATE_DIR, else
# $HOME/.claude/.state.
#
# SECURITY: the command string is untrusted data. It is NEVER evaluated or
# executed: no eval, no sh -c, no unquoted expansion into a command; jq gets it
# through --arg only. The gate does not try to understand shell text. It:
#  1. (S.1) decides whether the text is a candidate at all: continuations
#     joined, CRLF collapsed, ${...} removed, quotes, backslashes and backticks
#     removed, then the words git+push or gh/glab+create/new (git, gh and glab
#     case-insensitive). Anything else exits 0 with no git call (fast path).
#     Over 64 KB the same test decides: match denies (W_SIZE), else exit 0.
#  2. (S.2) splits the raw text with a small POSIX awk tokenizer (LC_ALL=C,
#     byte semantics) over whitespace and quotes only. Every accepted token is
#     a literal word: any of $ ` { } ( ) * ? [ < | & ; # or a control character
#     anywhere (quoted or not), other than one && or ; joiner and trailing
#     redirections (>, >>, N>, N>&M, PowerShell *>&1), makes the text not plain.
#     A backslash is literal in the PowerShell dialect (tool_name PowerShell)
#     and allowed only inside single quotes otherwise; PowerShell '' and ""
#     inside quotes and curly quotes are quotes; a PowerShell , or a word
#     starting @x outside quotes is not plain.
#  3. accepts exactly: [cd <dir> && | cd <dir>; | Set-Location <dir>;]
#     git [-C <dir>] push [allowlisted options] [<remote> [<refspec>]], or
#     gh pr create|new ... / glab mr create|new ... (one location prefix at
#     most). Every other candidate is denied W_PLAIN (S.3).
#  4. (S.4) judges the plain command: destination from the refspec, bare
#     refspec remap (remote.<r>.push, push.default upstream/tracking), or the
#     @{push}/upstream/current-branch chain; then the marker. It only asks git
#     read-only questions (rev-parse, symbolic-ref, remote, rev-list,
#     merge-base, config); no network. User-derived ref words reach git after
#     --end-of-options where the subcommand supports it. A wall-clock budget of
#     8 s from hook start denies any candidate still undecided (W_TIME).
#
# Always exits 0. Output nothing to allow; to deny print the single-line JSON
# hookSpecificOutput permissionDecision deny. Fail-open (exit 0, no output):
# AF_CODE_REVIEW_GATE=off, missing jq, malformed JSON, non-object tool_input,
# missing or non-string command, empty session_id after sanitising (checked
# before the candidate and size tests), a push whose payload cwd is not inside
# a git repository (git rev-parse --git-dir fails), a repository with no refs
# at all (an unborn HEAD in a repository that has other refs is gated), any unexpected
# internal error. Not fail-open: a non-plain candidate (W_PLAIN), a cd/-C
# directory that is missing or not a git work tree (W_LOC), a pull/merge
# request from a directory that is not a git work tree (W_NOREPO).

trap 'exit 0' EXIT
set -f

NL='
'
OLDIFS=$IFS

# --- switch, prerequisites, payload -----------------------------------------
if [ -n "${AF_CODE_REVIEW_GATE:-}" ]; then
  gate_env=$(printf '%s' "$AF_CODE_REVIEW_GATE" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ "$gate_env" = "off" ] && exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

# wall-clock budget, started at hook entry: SECONDS when the shell keeps it (bash,
# zsh, ksh), measured as a delta from here so an inherited value never counts;
# else date +%s.
t_mode=d
# shellcheck disable=SC3028
if [ -n "${BASH_VERSION:-}${ZSH_VERSION:-}${KSH_VERSION:-}" ]; then
  case ${SECONDS:-x} in
    *[!0-9]*) ;;
    *) t_mode=s; s0=$SECONDS ;;
  esac
fi
if [ "$t_mode" = d ]; then t0=$(date +%s 2>/dev/null) || t_mode=none; fi

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Four fields, newline separated; the first three have CR/LF removed, the
# command (last) keeps its newlines.
parsed=$(printf '%s' "$payload" | jq -j '
  def one: if type == "string" then gsub("[\r\n]"; "") else "" end;
  if (type == "object") and ((.tool_input | type) == "object") and ((.tool_input.command | type) == "string")
  then ((.session_id // "" | one) + "\n" + (.cwd // "" | one) + "\n" + (.tool_name // "" | one)
        + "\n" + .tool_input.command)
  else empty end' 2>/dev/null) || exit 0
[ -n "$parsed" ] || exit 0

sid=${parsed%%"$NL"*};  rest=${parsed#*"$NL"}
cwd0=${rest%%"$NL"*};   rest=${rest#*"$NL"}
tool=${rest%%"$NL"*}
case $rest in
  *"$NL"*) cmd=${rest#*"$NL"} ;;
  *) cmd="" ;;
esac
[ -n "$cmd" ] || exit 0

US=$(printf '\037')
STX=$(printf '\002')
CR=$(printf '\r')

# --- deny helper and wordings -------------------------------------------------
deny() {
  # $1 command kind, $2 specific sentence, $3 review target
  dn_reason="Code-review gate: ${1} denied. ${2} Review target: ${3}. To unlock: launch the code-review-gatekeeper sub-agent (Agent tool, subagent_type: code-review-gatekeeper) and have it apply agentic-framework:code-review to that target (${3}); the command is allowed once VERDICT: APPROVED is recorded at the current HEAD against that base. Setting AF_CODE_REVIEW_GATE=off in the launch environment disables this gate (a restart is needed)."
  dn_reason=$(printf '%s' "$dn_reason" | LC_ALL=C tr -cd '\040-\176' | tr -d '"<>&')
  jq -cn --arg r "$dn_reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
  exit 0
}

chk_time() {
  # shellcheck disable=SC3028
  case $t_mode in
    s) [ $((SECONDS - s0)) -ge 8 ] || return 0 ;;
    d) ct_now=$(date +%s 2>/dev/null) || return 0; [ $((ct_now - t0)) -ge 8 ] || return 0 ;;
    *) return 0 ;;
  esac
  deny "$K_ANY" "$W_TIME" "$T_ANY"
}

K_ANY="git push or pull request creation"
T_ANY="the current branch against its destination"
W_PLAIN="The command text is not a plain push or pull request command. The gate allows a push or a PR/MR creation only as its own command with literal names: git push REMOTE REFSPEC, gh pr create ..., glab mr create ..., optionally after one cd DIR (joined by a double ampersand or a semicolon) or as git -C DIR push. Split chained commands, variables, substitutions, wrappers and scripts into separate plain commands; pass a multi-line PR body with --body-file. If this command is not a push or a PR creation, its text still mentions one: reword it or move the text to a file."
W_SIZE="The command text is unresolvable: it is longer than 64 KB and appears to contain a push or a pull request creation, so the gate does not parse it. Split it into separate, smaller commands."
W_TIME="The command text is unresolvable: the gate ran out of time deciding it (more than 8 seconds). Split it into separate, smaller commands."
W_LOC="The command text is unresolvable: the cd, Set-Location or git -C directory does not exist or is not a git work tree, so the repository is unknown. Run the command from the repository itself."
W_NOREPO="The command text is unresolvable: the pull or merge request is created from a directory that is not a git work tree, so the commit to propose cannot be identified. Run it from the repository whose branch is proposed."
W_REFMAP="The push destination cannot be resolved: a remote.REMOTE.push entry matches this branch but does not name a single destination branch. Push with an explicit source:destination refspec."

# --- candidate test (S.1) -----------------------------------------------------
# Prints "<candidate 0|1> <oversize 0|1>". Bytes under LC_ALL=C.
# shellcheck disable=SC2016
FP_PROG='
# Linear in the text length (decision S 3-bis s): no gsub with many matches (it is
# quadratic in the match count); split-and-join for the fixed removals, one
# character pass per spelling for the rest.
function rep(t, re, r,   n, a, k, o) {
  n = split(t, a, re)
  if (n < 2) return t
  o = a[1]
  for (k = 2; k <= n; k++) o = o r a[k]
  return o
}
# scan(t, mode): 1 = spelling with ${...} removed, 2 = spelling with only ${ and }
# removed. Quotes, backslashes and backticks are transparent (a word continues
# across them). A word is a maximal run of letters and digits; "push" directly
# followed by a dot is not a push; "push" whose two previous words are exactly
# "git" "stash" as the first two words of a text that has nothing but whitespace
# before them (the text begins "git stash push") is not a push; the separators
# between and after those words may be anything (the .ps1 regex agrees).
function scan(t, mode,   n, i, j, c, cw, pw, ppw, lc, k, g, p, h, m, cr, lw, dot, wc, clean) {
  n = length(t); lc = 0
  if (mode == 1) for (k = n; k >= 1; k--) if (substr(t, k, 1) == "}") { lc = k; break }
  g = 0; p = 0; h = 0; m = 0; cr = 0; pw = ""; ppw = ""; cw = ""; wc = 0; clean = 1
  for (i = 1; i <= n + 1; i++) {
    dot = 0
    if (i <= n) {
      c = substr(t, i, 1)
      if (c == DQ || c == SQ || c == BS || c == BT) continue
      if (c == "$" && substr(t, i + 1, 1) == "{") {
        if (mode == 2) { i++; continue }
        if (lc >= i + 2) { j = i + 2; while (substr(t, j, 1) != "}") j++; i = j; continue }
      }
      if (mode == 2 && c == "}") continue
      if (index(ALNUM, c) > 0) { cw = cw c; continue }
      dot = (c == ".") ? 1 : 0
      if (wc == 0 && cw == "" && c != " " && c != "\t" && c != "\r" && c != "\n") clean = 0
    }
    if (cw != "") {
      lw = tolower(cw)
      if (lw == "git") g = 1
      if (lw == "gh" || lw == "glab") h = 1
      if (cw == "push") {
        if (dot) cw = "pushdot"
        else if (!(wc == 2 && clean && pw == "stash" && ppw == "git")) p = 1
      }
      if (cw == "pr" || cw == "mr") m = 1
      if (cw == "create" || cw == "new") cr = 1
      if ((g && p) || (h && m && cr)) return 1
      ppw = pw; pw = cw; cw = ""; wc++
    }
  }
  return 0
}
BEGIN {
  RS = sprintf("%c", 1); DQ = "\""; SQ = sprintf("%c", 39); BS = "\\"; BT = "`"
  ALNUM = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  CURLY = ""
  for (k = 152; k <= 158; k++) CURLY = CURLY (k > 152 ? "|" : "") sprintf("%c%c%c", 226, 128, k)
}
{ s = (NR > 1) ? s RS $0 : $0 }
END {
  big = (length(s) > 65536) ? 1 : 0
  s = rep(s, "[\\\\`]\r?\n", "")
  s = rep(s, "\r\n", "\n")
  s = rep(s, CURLY, "")
  s = rep(s, "\\$[\"\047]", "")
  printf "%d %d", (scan(s, 1) || scan(s, 2)) ? 1 : 0, big
}'
sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9_-')
[ -n "$sid" ] || exit 0
fp=$(printf '%s' "$cmd" | LC_ALL=C awk "$FP_PROG" 2>/dev/null) || exit 0
case $fp in
  "1 1") deny "$K_ANY" "$W_SIZE" "$T_ANY" ;;
  "1 0") ;;
  *) exit 0 ;;
esac

# jq on Windows writes its "\n" separators as CRLF: drop the CR that ends the field.
tool=${tool%"$CR"}
case $tool in
  PowerShell|powershell|POWERSHELL) dialect_ps=1 ;;
  *) dialect_ps=0 ;;
esac

cwd0=$(printf '%s' "$cwd0" | tr -d '\r')
if [ -z "$cwd0" ] || [ ! -d "$cwd0" ]; then
  cwd0=$(pwd 2>/dev/null) || exit 0
fi

state_root=${CLAUDE_STATE_DIR:-}
[ -n "$state_root" ] || state_root=${HOME:-}/.claude/.state
marker=$state_root/code-review/$sid

# --- plain-form tokenizer (S.2) -----------------------------------------------
# Output: "OK" then one line per token: W<word> or O<joiner> (&& or ;); trailing
# redirections are consumed. "BAD" when the text is not plain.
# shellcheck disable=SC2016
TOK_PROG='
function fail() { print "BAD"; exit }
function badc(c) { return (index(BADS, c) > 0 || index(CTRL, c) > 0) }
function emit(w,   qp) {
  qp = qpre; qpre = 0; sl = 0
  if (w == "" && !wq) fail()
  if (rt) { rt = 0; return }
  if (nr) fail()
  if (PSD && substr(w, 1, 1) == "@" && length(w) > 1 && !wq) fail()
  # a Bash word with a quote before its first unquoted slash is not tilde-expanded
  # by the shell: mark a leading tilde so a quoted directory is not read as HOME
  # (S.3-bis e, n)
  if (!PSD && qp && substr(w, 1, 1) == "~") w = STX w
  out = out "W" w "\n"
}
# a PowerShell word that begins with a quoted string may not continue (S.3-bis t)
function contfail(p,   x) {
  x = substr(s, p, 1)
  if (x != "" && x != " " && x != "\t" && x != ";" && substr(s, p, 2) != "&&") fail()
}
function op(o) { if (nr || rt) fail(); out = out "O" o "\n" }
BEGIN {
  RS = sprintf("%c", 1); SQ = sprintf("%c", 39); DQ = "\""; BS = "\\"
  BADS = "$`{}()*?[<|&;#"
  CTRL = ""
  for (k = 1; k < 32; k++) if (k != 9) CTRL = CTRL sprintf("%c", k)
  CTRL = CTRL sprintf("%c", 127)
  HIGH = ""
  for (k = 128; k < 256; k++) HIGH = HIGH sprintf("%c", k)
  STX = sprintf("%c", 2)
}
{ s = (NR > 1) ? s RS $0 : $0 }
END {
  sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s)
  n = length(s); i = 1; cur = ""; inw = 0; wq = 0; q = ""; nr = 0; rt = 0; out = ""
  qpre = 0; sl = 0; qbeg = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (q != "") {
      if (c == q) {
        if (PSD && substr(s, i + 1, 1) == q) { cur = cur c; i += 2; continue }
        q = ""
        if (qbeg) contfail(i + 1)
        qbeg = 0; i++; continue
      }
      if (badc(c)) fail()
      if (c == BS && !PSD && q == DQ) fail()
      if (PSD && index(HIGH, c) > 0) fail()
      cur = cur c; i++; continue
    }
    if (c == " " || c == "\t") { if (inw) { emit(cur); cur = ""; inw = 0; wq = 0 }; i++; continue }
    if (c == DQ || c == SQ) {
      # a closed quoted string with no $ ` backslash or control character is one
      # literal token: the banned characters inside it are data (S.2)
      if (!PSD && !sl) qpre = 1
      qb = (PSD && !inw) ? 1 : 0
      k = i + 1
      while (k <= n) {
        ch = substr(s, k, 1)
        if (ch == c) { if (PSD && substr(s, k + 1, 1) == c) { k += 2; continue }; break }
        k++
      }
      if (k <= n) {
        raw = substr(s, i + 1, k - i - 1); clean = 1
        if (index(raw, "$") > 0 || index(raw, "`") > 0 || index(raw, BS) > 0) clean = 0
        for (z = 1; clean && z <= length(raw); z++) {
          ch = substr(raw, z, 1)
          if (index(CTRL, ch) > 0) clean = 0
        }
        if (clean) {
          if (PSD) gsub(c c, c, raw)
          if (qb) contfail(k + 1)
          cur = cur raw; inw = 1; wq = 1; i = k + 1; continue
        }
      }
      q = c; qbeg = qb; inw = 1; wq = 1; i++; continue
    }
    if (substr(s, i, 2) == "&&") { if (inw) { emit(cur); cur = ""; inw = 0; wq = 0 }; op("&&"); i += 2; continue }
    if (c == ";") { if (inw) { emit(cur); cur = ""; inw = 0; wq = 0 }; op(";"); i++; continue }
    if (!inw) {
      rest = substr(s, i, 8)
      m = PSD ? match(rest, /^[0-9*]?>>?(&[0-9])?/) : match(rest, /^[0-9]?>>?(&[0-9])?/)
      if (m) {
        if (rt) fail()
        tk = substr(rest, 1, RLENGTH); i += RLENGTH; nr = 1
        if (index(tk, "&") > 0) {
          nx = substr(s, i, 1)
          if (nx != "" && nx != " " && nx != "\t") fail()
        } else rt = 1
        continue
      }
    }
    if (c == ">") fail()
    if (c == BS && !PSD) fail()
    if (PSD && c == ",") fail()
    if (PSD && index(HIGH, c) > 0) fail()
    if (badc(c)) fail()
    if (c == "/") sl = 1
    cur = cur c; inw = 1; i++
  }
  if (q != "") fail()
  if (inw) emit(cur)
  if (rt) fail()
  printf "OK\n%s", out
}'

not_plain() { deny "$K_ANY" "$W_PLAIN" "$T_ANY"; }

tcmd=$cmd
if [ "$dialect_ps" = 1 ]; then
  q1=$(printf '\342\200\230'); q2=$(printf '\342\200\231'); q3=$(printf '\342\200\232'); q4=$(printf '\342\200\233')
  d1=$(printf '\342\200\234'); d2=$(printf '\342\200\235'); d3=$(printf '\342\200\236')
  tcmd=$(printf '%s' "$cmd" | LC_ALL=C sed -e "s/$q1/'/g" -e "s/$q2/'/g" -e "s/$q3/'/g" -e "s/$q4/'/g" \
    -e "s/$d1/\"/g" -e "s/$d2/\"/g" -e "s/$d3/\"/g" 2>/dev/null) || not_plain
fi
toks=$(printf '%s' "$tcmd" | LC_ALL=C awk -v PSD="$dialect_ps" "$TOK_PROG" 2>/dev/null) || not_plain
case $toks in
  OK) toks="" ;;
  OK"$NL"*) toks=${toks#OK"$NL"} ;;
  *) not_plain ;;
esac
[ -n "$toks" ] || not_plain
IFS=$NL
# shellcheck disable=SC2086
set -- $toks
IFS=$OLDIFS

# --- grammar: one optional location prefix, then one command ------------------
loc=""; has_loc=0; lp=0
case $1 in
  Wcd) lp=1 ;;
  W[Cc][Dd]) [ "$dialect_ps" = 1 ] && lp=1 ;;
  W[Ss][Ee][Tt]-[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]) [ "$dialect_ps" = 1 ] && lp=2 ;;
esac
if [ "$lp" != 0 ]; then
  [ $# -ge 3 ] || not_plain
  case $2 in W?*) loc=${2#W} ;; *) not_plain ;; esac
  case $3 in
    "O&&") [ "$lp" = 1 ] || not_plain ;;
    "O;") ;;
    *) not_plain ;;
  esac
  has_loc=1
  shift 3
fi
[ $# -ge 1 ] || not_plain
for t in "$@"; do
  case $t in O*) not_plain ;; esac
done

kind=""
case $1 in
  Wgit)
    shift
    if [ "${1:-}" = W-C ] && [ "$has_loc" = 0 ]; then
      [ $# -ge 2 ] || not_plain
      loc=${2#W}; has_loc=1; shift 2
    fi
    [ "${1:-}" = Wpush ] || not_plain
    shift; kind=push ;;
  Wgh)
    [ "${2:-}" = Wpr ] || not_plain
    case ${3:-} in Wcreate|Wnew) ;; *) not_plain ;; esac
    shift 3; kind=gh ;;
  Wglab)
    [ "${2:-}" = Wmr ] || not_plain
    case ${3:-} in Wcreate|Wnew) ;; *) not_plain ;; esac
    shift 3; kind=glab ;;
  *) not_plain ;;
esac
if [ "$has_loc" = 1 ]; then
  [ -n "$loc" ] || not_plain
  # option-looking, UNC/network (decided before any filesystem access), ~user, and
  # a quoted tilde (not expanded by a Bash shell) are not plain
  # shellcheck disable=SC2088
  case $loc in
    [A-Za-z]:|[A-Za-z]:[!/\\]*) not_plain ;;
    \\[!\\/]*|\\) not_plain ;;
    -*|//*|\\\\*|/\\*|\\/*|"$STX"*) not_plain ;;
    "~"|"~/"*|"~\\"*) ;;
    "~"*) not_plain ;;
  esac
  # the MSYS drive form /c/... is Bash-dialect only (S.3-bis m)
  if [ "$dialect_ps" = 1 ]; then
    case $loc in /*) not_plain ;; esac
  fi
fi
# tokens keep their W prefix so an empty quoted value stays one field
args=""
tn=0
for t in "$@"; do
  args=$args$t$NL
  tn=$((tn + 1))
  [ $((tn % 2000)) -ne 0 ] || chk_time
done
chk_time
IFS=$NL
# shellcheck disable=SC2086
set -- $args
IFS=$OLDIFS

# --- helpers ----------------------------------------------------------------
gdir=""; headsha=""; branch=""; remote=""
PREP_DONE=0; PREP_WT=0; memo_head=""; memo_rb=""; memo_rl=0; memo_remotes=""
CACHE=$NL

# Memo store: records "<key>US<value>" one per line; keys and values hold no newline.
cache_get() {
  case $CACHE in
    *"$NL$1$US"*) CV=${CACHE#*"$NL$1$US"}; CV=${CV%%"$NL"*}; return 0 ;;
  esac
  return 1
}
cache_put() { CACHE=$CACHE$1$US$2$NL; }

# nl_join <text> <sep>: NJ = text with each newline replaced by sep (no fork).
nl_join() {
  NJ=$1
  while :; do
    case $NJ in
      *"$NL"*) NJ=${NJ%%"$NL"*}$2${NJ#*"$NL"} ;;
      *) break ;;
    esac
  done
}

# resolve_loc: gdir = the location prefix's directory (or the payload cwd);
# a location that is not an existing directory denies W_LOC ($1 kind label).
resolve_loc() {
  gdir=$cwd0
  [ "$has_loc" = 1 ] || return 0
  rl_d=$loc
  # SC2088: the patterns match a literal tilde in the command text on purpose
  # shellcheck disable=SC2088
  case $rl_d in
    "~") [ -n "${HOME:-}" ] || deny "$1" "$W_LOC" "HEAD vs its destination"; rl_d=$HOME ;;
    "~/"*) [ -n "${HOME:-}" ] || deny "$1" "$W_LOC" "HEAD vs its destination"; rl_d=$HOME/${rl_d#"~/"} ;;
    "~\\"*) [ -n "${HOME:-}" ] || deny "$1" "$W_LOC" "HEAD vs its destination"; rl_d=$HOME/${rl_d#"~\\"} ;;
    /*|[A-Za-z]:*|\\*) ;;
    *) rl_d=$cwd0/$rl_d ;;
  esac
  [ -d "$rl_d" ] || deny "$1" "$W_LOC" "HEAD vs its destination"
  gdir=$rl_d
}

load_remotes() {
  if [ "$memo_rl" != 1 ]; then
    memo_remotes=$(git -C "$gdir" remote 2>/dev/null) || memo_remotes=""
    nl_join "$memo_remotes" " "; memo_remotes=$NJ
    memo_rl=1
  fi
}

is_remote() {
  for ir_r in $memo_remotes; do
    [ "$ir_r" = "$1" ] && return 0
  done
  return 1
}

# cfg_all <key>: CFG = every value of the git config key in gdir, newline separated (memoised).
cfg_all() {
  if ! cache_get "G$1"; then
    CV=$(git -C "$gdir" config --get-all "$1" 2>/dev/null) || CV=""
    nl_join "$CV" "$US"; CV=$NJ
    cache_put "G$1" "$CV"
  fi
  CFG=$CV
  while :; do
    case $CFG in
      *"$US"*) CFG=${CFG%%"$US"*}$NL${CFG#*"$US"} ;;
      *) break ;;
    esac
  done
}

# Sets headsha, branch and PREP_WT for gdir (memoised); returns 1 when the
# candidate cannot be judged (not a work tree, or an unborn HEAD).
prep_repo() {
  if [ "$PREP_DONE" != 1 ]; then
    chk_time
    PREP_DONE=1
    if pr_out=$(git -C "$gdir" rev-parse --is-inside-work-tree HEAD 2>/dev/null); then
      if [ "${pr_out%%"$NL"*}" = "true" ]; then PREP_WT=1; memo_head=${pr_out#*"$NL"}; fi
    else
      chk_time
      pr_out=$(git -C "$gdir" rev-parse --is-inside-work-tree 2>/dev/null) || pr_out=""
      [ "$pr_out" = "true" ] && PREP_WT=1
    fi
    chk_time
    if [ -n "$memo_head" ]; then
      memo_rb=$(git -C "$gdir" symbolic-ref --short --quiet HEAD 2>/dev/null) || memo_rb=""
    fi
  fi
  headsha=$memo_head
  branch=$memo_rb
  [ "$PREP_WT" = 1 ] && [ -n "$headsha" ]
}

# need_repo: prep_repo; returns 1 (fail open) when the payload's own cwd is not
# a work tree or HEAD is unborn; a cd/-C directory that is not a git work tree
# denies W_LOC.
need_repo() {
  prep_repo && return 0
  chk_time
  if ! git -C "$gdir" rev-parse --git-dir >/dev/null 2>&1; then
    # not a repository at all: the payload cwd fails open, a cd/-C directory denies
    [ "$has_loc" = 1 ] || return 1
    deny "git push" "$W_LOC" "HEAD vs ${remote:-origin}/an unresolved destination"
  fi
  # a bare repository or a directory inside .git is gated like any repository
  [ "$PREP_WT" = 1 ] || deny "git push" "$W_LOC" "HEAD vs ${remote:-origin}/an unresolved destination"
  # unborn HEAD: only a repository with no refs at all fails open
  nr_refs=$(git -C "$gdir" for-each-ref --count=1 --format=x 2>/dev/null) || nr_refs=""
  [ -n "$nr_refs" ] || return 1
  headsha=""
  branch=$(git -C "$gdir" symbolic-ref --short --quiet HEAD 2>/dev/null) || branch=""
  memo_rb=$branch
  return 0
}

# remote_of_ref <full ref>: the longest configured remote whose refs/remotes/<r>/ prefixes it.
remote_of_ref() {
  case $1 in refs/remotes/*) ;; *) return 1 ;; esac
  ror_rest=${1#refs/remotes/}; ROR_R=""; ROR_B=""
  for ror_r in $memo_remotes; do
    case $ror_rest in
      "$ror_r"/*)
        if [ "${#ror_r}" -gt "${#ROR_R}" ]; then ROR_R=$ror_r; ROR_B=${ror_rest#"$ror_r"/}; fi ;;
    esac
  done
  [ -n "$ROR_R" ]
}

# resolve_chain: RR = the remote a push with no remote named goes to (@{push},
# branch.<b>.pushRemote, remote.pushDefault, branch.<b>.remote, origin); RPD =
# the destination @{push} or @{upstream} names, remote prefix removed.
resolve_chain() {
  RR=""; RPD=""
  load_remotes
  if cache_get "C$branch"; then RR=${CV%%"$US"*}; RPD=${CV#*"$US"}; return 0; fi
  chk_time
  if [ -n "$branch" ]; then
    rc_full=$(git -C "$gdir" rev-parse --symbolic-full-name "${branch}@{push}" 2>/dev/null) || rc_full=""
    if remote_of_ref "$rc_full"; then RR=$ROR_R; RPD=$ROR_B; fi
    if [ -z "$RR" ]; then
      for rc_key in "branch.${branch}.pushRemote" remote.pushDefault "branch.${branch}.remote"; do
        rc_v=$(git -C "$gdir" config --get "$rc_key" 2>/dev/null) || rc_v=""
        if [ -n "$rc_v" ]; then RR=$rc_v; break; fi
      done
    fi
    if [ -z "$RPD" ]; then
      rc_full=$(git -C "$gdir" rev-parse --symbolic-full-name "${branch}@{upstream}" 2>/dev/null) || rc_full=""
      case $rc_full in
        refs/heads/*) RPD=${rc_full#refs/heads/} ;;
        *) if remote_of_ref "$rc_full"; then RPD=$ROR_B; fi ;;
      esac
    fi
  else
    rc_v=$(git -C "$gdir" config --get remote.pushDefault 2>/dev/null) || rc_v=""
    RR=$rc_v
  fi
  [ -n "$RR" ] || RR=origin
  cache_put "C$branch" "$RR$US$RPD"
}

tgt_push() {
  # $1 destination; sets TGT
  TGT="${branch:-HEAD} vs ${remote}/${1}"
  tg_n=$(git -C "$gdir" rev-list --count --end-of-options "refs/remotes/${remote}/${1}..HEAD" 2>/dev/null) || tg_n=""
  case $tg_n in
    ''|*[!0-9]*) ;;
    *) TGT="$TGT ($tg_n commits ahead)" ;;
  esac
}

commit_of() {
  # commit_of <rev>: CO = the full sha, or empty
  CO=$(git -C "$gdir" rev-parse --verify --quiet --end-of-options "$1^{commit}" 2>/dev/null) || CO=""
}

# Unlock rule (REQ-004, I-ter.8). Returns 0 when the marker unlocks; else denies.
# Uses gdir, headsha, branch, remote. $4: push | pr.
check_marker() {
  ck_kind=$1; ck_target=$2; ck_dest=$3; ck_mode=$4
  chk_time
  m_verdict=""; m_head=""; m_target=""
  if [ ! -f "$marker" ]; then
    deny "$ck_kind" "No code-review-gatekeeper review is recorded for this session, so nothing vouches for this change." "$ck_target"
  fi
  if [ -r "$marker" ]; then
    while IFS= read -r ml || [ -n "$ml" ]; do
      ml=${ml%"$CR"}
      case $ml in
        verdict=*) [ -n "$m_verdict" ] || m_verdict=${ml#verdict=} ;;
        head=*) [ -n "$m_head" ] || m_head=${ml#head=} ;;
        target=*) [ -n "$m_target" ] || m_target=${ml#target=} ;;
      esac
    done < "$marker"
  fi
  case $m_verdict in
    APPROVED|CHANGES_REQUIRED) ;;
    *) deny "$ck_kind" "No code-review-gatekeeper review verdict is recorded for this session, so nothing vouches for this change." "$ck_target" ;;
  esac
  ck_base=""; ck_mb=""; ck_hd=""
  case $m_target in
    "uncommitted @ "*|"paths "*) ;;
    *)
      ck_base=$(printf '%s\n' "$m_target" | sed -n 's/^[^ ].* vs \([^ ][^ ]*\) (.*$/\1/p')
      ck_rng=$(printf '%s\n' "$m_target" | sed -n 's/^[^ ].* vs [^ ][^ ]* (\([0-9a-f]\{7,40\}\)\.\.\([0-9a-f]\{7,40\}\)).*$/\1 \2/p')
      if [ -n "$ck_rng" ]; then ck_mb=${ck_rng%% *}; ck_hd=${ck_rng#* }; fi ;;
  esac
  if [ -n "$ck_hd" ]; then
    commit_of "$ck_hd"
    if [ "$CO" != "$headsha" ]; then
      deny "$ck_kind" "The recorded review is stale: its reviewed range ends at ${CO:-$ck_hd} but HEAD is now ${headsha} (a commit, amend or rebase came after the review). Re-run the review at the current HEAD." "$ck_target"
    fi
  fi
  if [ "$m_head" != "$headsha" ]; then
    deny "$ck_kind" "The recorded review is stale: it was made at ${m_head:-no recorded head} but HEAD is now ${headsha} (a commit, amend or rebase came after the review). Re-run the review at the current HEAD." "$ck_target"
  fi
  if [ "$m_verdict" = "CHANGES_REQUIRED" ]; then
    deny "$ck_kind" "The recorded review at this HEAD returned CHANGES_REQUIRED. Resolve every open finding, then re-run the review." "$ck_target"
  fi
  if [ -z "$ck_base" ]; then
    deny "$ck_kind" "The recorded review did not cover the branch against its destination (its target was: ${m_target:-none recorded}). Only a review of the branch against the destination unlocks this." "$ck_target"
  fi
  # base: a leading <r>/ is removed when <r> is the resolved remote, or for a PR the
  # remote refs/remotes/origin/HEAD points into (I-ter.11)
  ck_sb=$ck_base; ck_rr=$remote; ck_oh=""
  if [ "$ck_mode" = pr ]; then
    load_remotes
    ck_ohf=$(git -C "$gdir" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || ck_ohf=""
    if remote_of_ref "$ck_ohf"; then ck_oh=$ROR_R; fi
  fi
  case $ck_sb in
    "$remote"/*) ck_sb=${ck_sb#"$remote"/} ;;
    *)
      if [ -n "$ck_oh" ]; then
        case $ck_sb in "$ck_oh"/*) ck_sb=${ck_sb#"$ck_oh"/}; ck_rr=$ck_oh ;; esac
      fi ;;
  esac
  if [ "$ck_sb" != "$ck_dest" ]; then
    deny "$ck_kind" "Base mismatch: the recorded review compared the branch with ${ck_base}, but this command lands on ${ck_dest}. Re-run the review against ${ck_dest}." "$ck_target"
  fi
  if [ -z "$ck_hd" ]; then
    deny "$ck_kind" "The recorded review is stale: its target names no reviewed range (merge-base..head), so the approval cannot be bound to the commits being sent. Re-run the review at the current HEAD." "$ck_target"
  fi
  commit_of "$ck_mb"; ck_mbc=$CO
  # the reviewed range must start on the remote-tracking ref of the destination only
  ck_refs="refs/remotes/${ck_rr}/${ck_dest}"
  if [ "$ck_mode" = pr ] && [ -n "$ck_oh" ] && [ "$ck_oh" != "$ck_rr" ]; then
    ck_refs="$ck_refs${NL}refs/remotes/${ck_oh}/${ck_dest}"
  fi
  # an empty range unlocks nothing while HEAD differs from the destination's remote tip
  if [ "$ck_mbc" = "$headsha" ]; then
    ck_tip=$(git -C "$gdir" rev-parse --verify --quiet --end-of-options "refs/remotes/${ck_rr}/${ck_dest}" 2>/dev/null) || ck_tip=""
    if [ "$ck_tip" != "$headsha" ]; then
      deny "$ck_kind" "The recorded review is stale: its reviewed range ${ck_mb}..${ck_hd} is empty while HEAD differs from ${ck_rr}/${ck_dest} (commits ahead or behind). Re-run the review at the current HEAD." "$ck_target"
    fi
  fi
  ck_ok=0
  if [ -n "$ck_mbc" ]; then
    while IFS= read -r ck_r; do
      [ -n "$ck_r" ] || continue
      if git -C "$gdir" merge-base --is-ancestor --end-of-options "$ck_mbc" "$ck_r" >/dev/null 2>&1; then ck_ok=1; break; fi
    done <<EOF
$ck_refs
EOF
  fi
  if [ "$ck_ok" != 1 ]; then
    deny "$ck_kind" "The recorded review is stale: its reviewed range starts at ${ck_mb}, which is not an ancestor of ${ck_rr}/${ck_dest} (the remote-tracking ref of the destination), so it does not cover every commit being sent. Re-run the review against ${ck_rr}/${ck_dest}." "$ck_target"
  fi
  # what the forge builds the request from must be what was reviewed
  if [ "$ck_mode" = pr ] && [ -n "$branch" ]; then
    ck_hr=$(git -C "$gdir" rev-parse --verify --quiet --end-of-options "refs/remotes/${remote}/${branch}" 2>/dev/null) || ck_hr=""
    if [ -n "$ck_hr" ] && [ "$ck_hr" != "$headsha" ]; then
      deny "$ck_kind" "The recorded review is stale for this request: the remote branch ${remote}/${branch} is at ${ck_hr}, not at HEAD ${headsha}, so the request would be built from commits other than the reviewed ones. Push HEAD to ${remote}/${branch} first, then open the request." "$ck_target"
    fi
  fi
  return 0
}

pr_default_dst() {
  pd_d=$(git -C "$gdir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || pd_d=""
  if [ -n "$pd_d" ]; then
    PDD=${pd_d#origin/}
  elif git -C "$gdir" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1 \
    || git -C "$gdir" rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1; then
    PDD=main
  else
    PDD=master
  fi
}

# classify_refs <refspecs, newline separated> <mark bare 0|1>: appends
# src US dst US bare lines to nrefs, sets all for the matching refspec or a
# wildcard, anygate when a destination is main, master or HEAD, anybare when a
# refspec is a bare name other than HEAD (its destination follows configuration).
classify_refs() {
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    r=${r#+}
    cr_b=0
    case $r in
      ''|:) all=1; continue ;;
      *'*'*) all=1; continue ;;
      *:*) src=${r%%:*}; dst=${r#*:} ;;
      *) src=$r; dst=$r; cr_b=$2 ;;
    esac
    [ -n "$src" ] || continue
    src=${src#refs/heads/}; src=${src#heads/}
    dst=${dst#refs/heads/}; dst=${dst#heads/}
    [ "$src" = @ ] && src=HEAD
    [ "$dst" = @ ] && dst=HEAD
    [ "$src" = HEAD ] && cr_b=0
    [ "$cr_b" = 1 ] && anybare=1
    case $dst in main|master|HEAD) anygate=1 ;; esac
    nrefs=$nrefs$src$US$dst$US$cr_b$NL
  done <<EOF
$1
EOF
}

# map_ref <full ref> <remote.<r>.push entries>: MR = the destination of the first
# entry whose source matches (git applies the entries as a refmap to a bare
# refspec). Returns 0 matched, 1 no entry matches, 2 a negative (^) entry exists or
# a matching entry whose destination cannot be resolved.
map_ref() {
  # any negative entry denies: git reverse-maps negatives through the positive
  # entries and the gate does not model that (S.3-bis o)
  case $NL$2 in *"$NL"^*|*"$NL+^"*) return 2 ;; esac
  while IFS= read -r mr_e; do
    [ -n "$mr_e" ] || continue
    mr_e=${mr_e#+}
    case $mr_e in
      *:*) mr_s=${mr_e%%:*}; mr_d=${mr_e#*:} ;;
      *) continue ;;
    esac
    case $mr_s in
      *'*'*)
        mr_pre=${mr_s%%\**}; mr_suf=${mr_s#*\*}
        case $mr_suf in *'*'*) return 2 ;; esac
        case $1 in "$mr_pre"*"$mr_suf") ;; *) continue ;; esac
        mr_mid=${1#"$mr_pre"}; mr_mid=${mr_mid%"$mr_suf"}
        case $mr_d in
          *'*'*) MR=${mr_d%%\**}$mr_mid${mr_d#*\*} ;;
          *) return 2 ;;
        esac ;;
      *)
        [ "$mr_s" = "$1" ] || continue
        MR=$mr_d ;;
    esac
    MR=${MR#refs/heads/}; MR=${MR#heads/}
    case $MR in ''|*'*'*) return 2 ;; esac
    return 0
  done <<EOF
$2
EOF
  return 1
}

# remap_bare: each bare refspec naming one local branch takes its destination
# from remote.<r>.push (a refmap), else under push.default upstream or tracking
# from a single-valued branch.<src>.merge (I-quater.3). Rewrites nrefs and anygate.
remap_bare() {
  cfg_all "remote.${remote}.push"; rb_map=$CFG
  cfg_all push.default; rb_pd=${CFG##*"$NL"}
  rb_up=0
  case $rb_pd in
    [Uu][Pp][Ss][Tt][Rr][Ee][Aa][Mm]|[Tt][Rr][Aa][Cc][Kk][Ii][Nn][Gg]) rb_up=1 ;;
  esac
  rb_out=""; anygate=0
  while IFS="$US" read -r rb_s rb_d rb_b; do
    [ -n "$rb_s" ] || continue
    if [ "$rb_b" = 1 ] && git -C "$gdir" rev-parse --verify --quiet "refs/heads/$rb_s" >/dev/null 2>&1 </dev/null; then
      rb_done=0
      if [ -n "$rb_map" ]; then
        map_ref "refs/heads/$rb_s" "$rb_map"
        case $? in
          0) rb_d=$MR; rb_done=1 ;;
          2) deny "git push" "$W_REFMAP" "${branch:-HEAD} vs ${remote}/an unresolved destination" ;;
        esac
      fi
      if [ "$rb_done" = 0 ] && [ "$rb_up" = 1 ]; then
        cfg_all "branch.${rb_s}.merge"
        case $CFG in
          ''|*"$NL"*) ;;
          *) rb_d=${CFG#refs/heads/}; rb_d=${rb_d#heads/} ;;
        esac
      fi
    fi
    case $rb_d in main|master|HEAD) anygate=1 ;; esac
    rb_out=$rb_out$rb_s$US$rb_d$US$rb_b$NL
  done <<EOF
$nrefs
EOF
  nrefs=$rb_out
}

# --- git push <args> (S.2 option allowlist, S.4 decision) ---------------------
# push_val <value>: in the PowerShell dialect (which splits native arguments on
# Unicode whitespace) an option value is held to the push alphabet.
push_val() {
  [ "$dialect_ps" = 1 ] || return 0
  case $1 in *[!A-Za-z0-9._/@:+=%,-]*) not_plain ;; esac
}

do_push() {
  dry=0; del=0; tags=0; all=0; mirror=0; remote=""; refs=""; npos=0
  dp_n=0
  while [ $# -gt 0 ]; do
    t=${1#W}; shift
    dp_n=$((dp_n + 1))
    [ $((dp_n % 2000)) -ne 0 ] || chk_time
    case $t in
      -u|--set-upstream|-f|--force|--force-with-lease|--follow-tags|--no-verify|-q|--quiet|-v|--verbose|--porcelain) ;;
      --force-with-lease=*) push_val "${t#--force-with-lease=}" ;;
      --push-option=*) push_val "${t#--push-option=}" ;;
      --tags) tags=1 ;;
      -n|--dry-run) dry=1 ;;
      -d|--delete) del=1 ;;
      -o) [ $# -gt 0 ] || not_plain; push_val "${1#W}"; shift ;;
      -*) not_plain ;;
      *)
        [ -n "$t" ] || not_plain
        npos=$((npos + 1))
        case $npos in
          1) remote=$t ;;
          2) refs=$t ;;
          *) not_plain ;;
        esac ;;
    esac
  done
  # S.2 quoting never relaxes the plain form: after unquoting, the remote and the
  # refspec must still be literal names (a quoted wildcard or space is not plain).
  case $remote$refs in *"$NL"*) not_plain ;; esac
  # Builtin case globs only (no external tool on a restricted PATH). The character
  # class is the spec's remote/refspec alphabets plus ':' '+' '=' '%' ',' so that
  # URL remotes and the ':dst' delete refspec keep their existing rows; '*', '?',
  # '[', '~', '^', space and every other quoted-only character deny.
  case $remote in *[!A-Za-z0-9._/@:+=%,-]*) not_plain ;; esac
  case $refs in *[!A-Za-z0-9._/@:+=%,-]*) not_plain ;; esac
  case $refs in :|+:) not_plain ;; esac
  # git splits a refspec at its last colon, so a second one changes the meaning
  case $refs in *:*:*) not_plain ;; esac
  [ "$dry" = 1 ] && exit 0
  [ "$del" = 1 ] && exit 0
  hasrefs=0; [ -n "$refs" ] && hasrefs=1

  # classify the explicit refspec before any git call
  nrefs=""; anygate=0; anybare=0
  [ "$hasrefs" = 1 ] && classify_refs "$refs" 1
  if [ "$hasrefs" = 1 ] && [ "$anygate" = 0 ] && [ "$anybare" = 0 ]; then exit 0; fi

  resolve_loc "git push"
  need_repo || exit 0
  load_remotes

  remote_named=1
  [ -n "$remote" ] || remote_named=0
  RR=""; RPD=""
  if [ "$hasrefs" = 0 ] || [ "$remote_named" = 0 ]; then resolve_chain; fi
  [ "$remote_named" = 1 ] || remote=$RR
  [ "$anybare" = 1 ] && remap_bare

  # persistent configuration of the remote (I-ter.7): remote.<r>.mirror, remote.<r>.push
  if [ "$hasrefs" = 0 ]; then
    cfg_all "remote.${remote}.mirror"
    case ${CFG##*"$NL"} in
      [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]|1) mirror=1 ;;
    esac
    if [ "$mirror" = 0 ]; then
      cfg_all "remote.${remote}.push"
      if [ -n "$CFG" ]; then hasrefs=1; classify_refs "$CFG" 0; fi
    fi
  fi
  if [ "$hasrefs" = 0 ] && [ "$mirror" = 0 ] && [ "$tags" = 1 ]; then exit 0; fi
  if [ "$hasrefs" = 1 ] && [ "$all" = 0 ] && [ "$mirror" = 0 ] && [ "$anygate" = 0 ]; then exit 0; fi

  pairs=""
  if [ -n "$nrefs" ]; then
    # shellcheck disable=SC2034  # pp_b takes the bare flag so dst stays one field
    while IFS="$US" read -r src dst pp_b; do
      [ -n "$src" ] || continue
      [ "$dst" = HEAD ] && dst=$branch
      case $dst in
        main|master) pairs=$pairs$src$US$dst$NL ;;
      esac
    done <<EOF
$nrefs
EOF
  fi
  if [ "$all" = 1 ] || [ "$mirror" = 1 ]; then
    for b in main master; do
      dp_l=$(git -C "$gdir" rev-parse --verify --quiet "refs/heads/$b" 2>/dev/null) || continue
      dp_r=$(git -C "$gdir" rev-parse --verify --quiet --end-of-options "refs/remotes/$remote/$b" 2>/dev/null) || dp_r=""
      [ "$dp_l" = "$dp_r" ] && continue
      pairs=$pairs$b$US$b$NL
    done
  elif [ "$hasrefs" = 0 ]; then
    cfg_all push.default
    if [ "${CFG##*"$NL"}" = matching ]; then
      for b in main master; do
        dp_l=$(git -C "$gdir" rev-parse --verify --quiet "refs/heads/$b" 2>/dev/null) || continue
        dp_r=$(git -C "$gdir" rev-parse --verify --quiet --end-of-options "refs/remotes/$remote/$b" 2>/dev/null) || dp_r=""
        [ "$dp_l" = "$dp_r" ] && continue
        pairs=$pairs$b$US$b$NL
      done
    elif [ -n "$branch" ]; then
      d=$branch
      if [ -n "$RPD" ] && { [ "$remote_named" = 0 ] || [ "$remote" = "$RR" ]; }; then d=$RPD; fi
      case $d in
        main|master) pairs=$pairs$branch$US$d$NL ;;
      esac
    fi
  fi
  [ -n "$pairs" ] || exit 0

  while IFS="$US" read -r src dst; do
    [ -n "$src" ] || continue
    chk_time
    if ! is_remote "$remote"; then
      tgt_push "$dst"
      deny "git push" "The push names ${remote}, which is not a configured remote. Use a configured remote name (git remote lists them)." "$TGT"
    fi
    # an unborn HEAD (no commit): no source can be HEAD
    if [ -z "$headsha" ] || { [ "$src" != HEAD ] && { [ -z "$branch" ] || [ "$src" != "$branch" ]; }; }; then
      tgt_push "$dst"
      unb=""; [ -n "$headsha" ] || unb=" (this branch has no commit yet)"
      deny "git push" "The gate reviews the checked-out commit and the push source ${src} is not HEAD${unb}. Check the source out first, then review and push." "$TGT"
    fi
    if ! dp_rsha=$(git -C "$gdir" rev-parse --verify --quiet --end-of-options "refs/remotes/$remote/$dst" 2>/dev/null); then
      tgt_push "$dst"
      deny "git push" "The remote-tracking ref ${remote}/${dst} is unknown locally, so the commits to push cannot be counted. Run git fetch ${remote} ${dst} and retry; a push to a remote branch that does not yet exist needs AF_CODE_REVIEW_GATE=off in the launch environment." "$TGT"
    fi
    [ "$dp_rsha" = "$headsha" ] && continue
    tgt_push "$dst"
    check_marker "git push" "$TGT" "$dst" push
  done <<EOF
$pairs
EOF
  exit 0
}

# --- gh pr create|new / glab mr create|new <args> -----------------------------
do_pr() {
  if [ "$kind" = glab ]; then
    pr_label="glab mr create"
    hl=--source-branch; hs=-s; bl=--target-branch; bs=-b
    vf=" --title -t --description -d --assignee -a --label -l --milestone -m --reviewer --target-project --repo -R --head -H --related-issue -i "
  else
    pr_label="gh pr create"
    hl=--head; hs=-H; bl=--base; bs=-B
    vf=" --title -t --body -b --body-file -F --assignee -a --label -l --milestone -m --project -p --reviewer -r --template -T --repo -R --recover "
  fi
  pr_src=""; pr_dst=""; pr_dry=0; pr_n=0
  # tokens carry a W prefix (an empty quoted value is the token W alone)
  while [ $# -gt 0 ]; do
    t=${1#W}; shift
    pr_n=$((pr_n + 1))
    [ $((pr_n % 2000)) -ne 0 ] || chk_time
    if [ "$t" = --dry-run ]; then pr_dry=1; continue; fi
    if [ "$t" = "$hl" ] || [ "$t" = "$hs" ]; then pr_src=${1:-}; pr_src=${pr_src#W}; [ $# -gt 0 ] && shift; continue; fi
    if [ "$t" = "$bl" ] || [ "$t" = "$bs" ]; then pr_dst=${1:-}; pr_dst=${pr_dst#W}; [ $# -gt 0 ] && shift; continue; fi
    case $t in
      --dry-run=*) not_plain ;;
      "$hl="*) pr_src=${t#"$hl="}; continue ;;
      "$bl="*) pr_dst=${t#"$bl="}; continue ;;
      --*) ;;
      -?) ;;
      -?*) not_plain ;;
    esac
    case $vf in
      *" $t "*) [ $# -gt 0 ] && shift ;;
    esac
  done
  [ "$pr_dry" = 1 ] && exit 0
  resolve_loc "$pr_label"
  if ! prep_repo; then
    [ "$PREP_WT" = 1 ] || deny "$pr_label" "$W_NOREPO" "HEAD vs ${pr_dst:-its destination}"
    # work tree without a commit: a repository with no refs at all denies W_NOREPO
    # (S.3-bis u, EDGE-007); with other refs no source can be HEAD (S.3-bis j)
    nr_refs=$(git -C "$gdir" for-each-ref --count=1 --format=x 2>/dev/null) || nr_refs=""
    [ -n "$nr_refs" ] || deny "$pr_label" "$W_NOREPO" "HEAD vs ${pr_dst:-its destination}"
    if [ -z "$pr_dst" ]; then pr_default_dst; pr_dst=$PDD; fi
    pr_ub=$(git -C "$gdir" symbolic-ref --short --quiet HEAD 2>/dev/null) || pr_ub=""
    deny "$pr_label" "The gate reviews the checked-out commit and the source ${pr_src:-HEAD} is not HEAD (this branch has no commit yet). Check the source out first, then review and open the request." "${pr_ub:-HEAD} vs ${pr_dst}"
  fi
  if [ -z "$pr_dst" ]; then pr_default_dst; pr_dst=$PDD; fi
  resolve_chain; remote=$RR
  pr_tgt="${branch:-HEAD} vs ${pr_dst}"
  if [ -n "$pr_src" ] && [ "$pr_src" != HEAD ] && { [ -z "$branch" ] || [ "$pr_src" != "$branch" ]; }; then
    deny "$pr_label" "The gate reviews the checked-out commit and the source ${pr_src} is not HEAD. Check the source out first, then review and open the request." "$pr_tgt"
  fi
  check_marker "$pr_label" "$pr_tgt" "$pr_dst" pr
  exit 0
}

if [ "$kind" = push ]; then do_push "$@"; else do_pr "$@"; fi
