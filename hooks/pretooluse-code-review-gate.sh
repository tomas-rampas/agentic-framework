#!/bin/sh
set -u
LC_ALL=C
export LC_ALL
# pretooluse-code-review-gate.sh - blocking PreToolUse hook (matcher: Bash|PowerShell).
#
# POSIX twin of pretooluse-code-review-gate.ps1; the grammar block is shared byte for
# byte; the .ps1 is the reference for decision T. The two must produce byte-identical
# deny output.
#
# Denies a shell command that opens a pull/merge request (gh pr create|new,
# glab mr create|new) or pushes to main/master (git push, force included)
# unless a code-review-gatekeeper sub-agent has recorded VERDICT: APPROVED for
# the exact commit (HEAD) against the exact destination, with a reviewed range
# (<merge-base>..<head-sha>) that binds the approval to the commits being sent,
# in the marker <state>/code-review/<session_id> written by record-subagent-run.
# Grammar: decisions S and T of specs/code-review-gate.md (a whitelist of plain
# forms written as one regex grammar); the unlock rule is REQ-004. State dir:
# CLAUDE_STATE_DIR, else $HOME/.claude/.state.
#
# SECURITY: the command string is untrusted data. It is NEVER evaluated or
# executed: the command string never reaches eval (the only evals read or assign GV_<NAME>
# variables whose names are validated against [A-Z0-9_]), no sh -c, no unquoted expansion into a command; jq gets it
# through --arg only. The gate does not try to understand shell text. Three regex
# stages, each a fixed number of tr, sed -E and grep -E passes over the command's
# bytes (LC_ALL=C, exported above), no loop over characters or tokens:
#  1. (S.1, T.2, T.11) candidate test: curly quotes and a $ before a quote
#     removed, then four spellings (${...} removed; ${ and } removed; ${NAME}
#     and ${NAME<op> removed, then }; ${...}, $(...), a backtick substitution
#     and $NAME / $1 / $@ style parameters removed), each without quotes,
#     backslashes and backticks, the anchored git stash push exempted, and each
#     tested twice, with every continuation pair deleted and read as one space;
#     then the words git+push or gh/glab+pr/mr+create/new (git, gh and glab
#     case-insensitive), one tr | sed -n | grep -c pipeline. A text with no g or G
#     exits 0 with no fork; anything else that is not a candidate exits 0 with no
#     git call (fast path). Over 64 KB (bytes) the same test decides: match
#     denies (W_SIZE), else exit 0; a failing tool keeps that rule: a failing tr before the
#     size test leaves the session id empty and exits 0 at any size (EDGE-007), and so does
#     the surrogate-copy sed (a payload-parse step, like any unparsable payload); a failing
#     candidate-test sed or grep only under the cap.
#  2. (FORM, T.3) the text, with CR and LF as SOH and SOH as STX (PowerShell
#     dialect: curly quotes mapped to ASCII quotes first), must be one plain form
#     of the grammar block below (B_FORM for Bash, P_FORM for PowerShell), one
#     grep -E: [cd <dir> && | cd <dir>; | Set-Location <dir>;]
#     git [-C <dir>] push [words] [redirections], or gh pr create|new ... /
#     glab mr create|new ...; a word is literal (bare bytes and clean quoted
#     strings). Every other candidate is denied W_PLAIN (S.3).
#  3. (token stage, T.4) one sed -E: a lexer pass and fixed passes make W/O
#     tokens; STRUCT reads kind, joiner or -C and directory; PUSHARG (push
#     allowlist) and PR1/PR2 (gh/glab options, the last --head/--base wins) read
#     the values left to right; an unread - word, a third positional or an empty
#     word is not plain. A failing FORM or token-stage tool denies W_PLAIN.
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
# missing or non-string command (a payload that fails to parse only because of a lone
# surrogate escape, backslash-u D800 to DFFF, is decided on a copy with U+FFFD, T.11d),
# empty session_id after sanitising (checked
# before the candidate and size tests), a push whose payload cwd is not inside
# a git repository (git rev-parse --git-dir fails), a repository with no refs
# at all (an unborn HEAD in a repository that has other refs is gated), any unexpected
# internal error outside the grammar stages. Not fail-open: a non-plain candidate
# (W_PLAIN, also any tool failure in the FORM or token stage), a cd/-C
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
jq_prog='
  def one: if type == "string" then gsub("[\r\n]"; "") else "" end;
  if (type == "object") and ((.tool_input | type) == "object") and ((.tool_input.command | type) == "string")
  then ((.session_id // "" | one) + "\n" + (.cwd // "" | one) + "\n" + (.tool_name // "" | one)
        + "\n" + .tool_input.command)
  else empty end'
#
# T.11(e) The payload is parsed without -b. Only when CRLF mode shows (the tool_name field ends
# with a CR, which only Windows jq's LF-to-CRLF translation produces) is the same program re-run
# with jq -b (binary output, jq 1.7+) on the same input, so the .sh sees exactly the bytes the
# .ps1 sees; a jq without -b keeps the detect-and-undo path further down. No extra spawn on
# Linux or on the Windows fast path.
parse_in=$payload
if ! parsed=$(printf '%s' "$payload" | jq -j "$jq_prog" 2>/dev/null); then
  # T.11(d): jq rejects the whole document over one lone surrogate escape (backslash-u D800
  # to DFFF); decide on a copy with each such escape replaced by U+FFFD (the fallback of
  # pretooluse-model-guard.sh). Any other parse failure keeps EDGE-007 (exit 0).
  sanitized=$(printf '%s' "$payload" | sed -E 's/\\u[dD][89a-fA-F][0-9a-fA-F]{2}/\\uFFFD/g' 2>/dev/null) || exit 0
  [ "$sanitized" != "$payload" ] || exit 0
  parse_in=$sanitized
  parsed=$(printf '%s' "$sanitized" | jq -j "$jq_prog" 2>/dev/null) || exit 0
fi
[ -n "$parsed" ] || exit 0

sid=${parsed%%"$NL"*};  rest=${parsed#*"$NL"}
cwd0=${rest%%"$NL"*};   rest=${rest#*"$NL"}
tool=${rest%%"$NL"*}
case $rest in
  *"$NL"*) cmd=${rest#*"$NL"} ;;
  *) cmd="" ;;
esac
[ -n "$cmd" ] || exit 0
# every keyword holds g or G, and no S.1 deletion adds one: exit with no fork
case $cmd in *[Gg]*) ;; *) exit 0 ;; esac

# Control bytes in one fork: SOH STX ETX TAB CR US, the markers (header K H J Z, lexer
# A-E, token L R, push V VE F FE, PR S SV SE, D DV DE with D = CR, N NE X XE). All marker
# bytes (A-E, L R, V VE F FE, S SV SE, DD DV DE, N NE X XE) are the same bytes in both
# twins; the header markers K H J Z and the field separator US (0x1F) are .sh-only (the .ps1
# keeps those header fields in variables). Then the raw bytes of <HI> and <CURLY>
# and the curly quote ranges. The stages guarantee each marker absent from the text
# they run on.
IFS=' '
# shellcheck disable=SC2046
set -- $(printf '\001 \002 \003 \011 \015 \037 \004 \005 \006 \007 \021 \022 \023 \024 \025 \026 \027 \030 \031 \032 \033 \034 \035 \036 \016 \017 \020 \013 \014 \010 \200 \377 \342\200 \230 \233 \234 \236')
IFS=$OLDIFS
[ $# -eq 37 ] || exit 0
SOH=$1; STX=$2; ETX=$3; TAB=$4; CR=$5; US=$6
M_K=$7; M_H=$8; M_J=$9; shift 9
M_Z=$1; M_A=$2; M_B=$3; M_C=$4; M_D=$5; M_E=$6; M_L=$7; M_R=$8; M_V=$9; shift 9
M_VE=$1; M_F=$2; M_FE=$3; M_S=$4; M_SV=$5; M_SE=$6; M_DV=$7; M_DE=$8; M_N=$9; shift 9
M_NE=$1; M_X=$2; M_XE=$3; HI0=$4; HI1=$5; CU0=$6; CU1=$7; CU4=$8; CU5=$9; shift 9
CU7=$1
M_DD=$CR

# T.11(e) exact CRLF handling. jq on Windows writes every LF of its output as CRLF. Preferred
# path: jq -b (re-run just above) writes binary, no CR is added, nothing to undo. Fallback for a
# jq without -b: a CR ends the tool_name field (detected here, then dropped) and every LF of the
# command arrives as CR LF (a CR LF as CR CR LF); exactly one CR before each LF of the command
# goes, restoring the bytes the .ps1 sees; the last line loses its CR too (jq wrote its LF, then
# the substitution above removed it). The undo uses sed -b where sed accepts it: Git for Windows'
# GNU sed reads a pipe in text mode and itself drops one CR before each LF, so plain sed would
# remove two. Elsewhere nothing changes.
crlf=0
case $tool in *"$CR") crlf=1; tool=${tool%"$CR"} ;; esac
if [ "$crlf" = 1 ]; then
  # preferred: the same program with -b on the same input; no CR reaches the grammar
  if parsed_b=$(printf '%s' "$parse_in" | jq -b -j "$jq_prog" 2>/dev/null) && [ -n "$parsed_b" ]; then
    sid=${parsed_b%%"$NL"*};  rest=${parsed_b#*"$NL"}
    cwd0=${rest%%"$NL"*};     rest=${rest#*"$NL"}
    tool=${rest%%"$NL"*}
    case $rest in
      *"$NL"*) cmd=${rest#*"$NL"} ;;
      *) cmd="" ;;
    esac
    crlf=0
    [ -n "$cmd" ] || exit 0
  fi
fi
if [ "$crlf" = 1 ]; then
  sed_b=
  if printf 'a' | sed -b 's/a/a/' >/dev/null 2>&1; then sed_b=-b; fi
  # shellcheck disable=SC2086
  cmd_u=$(printf '%s' "$cmd" | sed $sed_b "s/$CR\$//" 2>/dev/null) && cmd=$cmd_u
  [ -n "$cmd" ] || exit 0
fi

# --- deny helper and wordings -------------------------------------------------
deny() {
  # $1 command kind, $2 specific sentence, $3 review target
  dn_reason="Code-review gate: ${1} denied. ${2} Review target: ${3}. To unlock: launch the code-review-gatekeeper sub-agent (Agent tool, subagent_type: code-review-gatekeeper) and have it apply agentic-framework:code-review to that target (${3}); the command is allowed once VERDICT: APPROVED is recorded at the current HEAD against that base. Setting AF_CODE_REVIEW_GATE=off in the launch environment disables this gate (a restart is needed)."
  dn_reason=$(printf '%s' "$dn_reason" | tr -cd '\040-\176' | tr -d '"<>&')
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

not_plain() { deny "$K_ANY" "$W_PLAIN" "$T_ANY"; }

# --- grammar (decision T) -----------------------------------------------------
# The block below is shared byte for byte with the .ps1 (the equivalence suite
# compares them). Each line is NAME=TEXT; {NAME} refers to an earlier line and is
# expanded once per run by literal replacement (g_load). The placeholders <TAB> <BS>
# <HI> <CURLY> <Q> and the marker names are the only per-engine difference (g_tr).
# {X_CD}, {X_VF}, {HL}, {HS}, {BL}, {BS} select the dialect or the tool and are filled
# in where the pattern is used.
# shellcheck disable=SC2016
G_DEFS='
# --- S.1 candidate test (on the S.1 text)
S1_JOIN=[\\`]<CR>?<SOH>
S1_CURLY=<CURLY>
S1_DQ=\$["<Q>]
S1_BRACE1=\$\{[^}]*(\}|$)
S1_BRACE2O=\$\{
S1_BRACE2C=\}
S1_BRACE3V=\$\{[A-Z_a-z][0-9A-Z_a-z]*\}
S1_BRACE3O=\$\{[A-Z_a-z][0-9A-Z_a-z]*:?[+=?-]
S1_SUBST=\$\([^)]*(\)|$)
S1_BTICK=`[^`]*(`|$)
S1_PARAM=\$([A-Z_a-z][0-9A-Z_a-z]*|[0-9@*!#?$-])
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
'

# g_rep <text> <from> <to>: GR = text with every from replaced by to (no fork).
g_rep() {
  GR=""; gr_t=$1
  while :; do
    case $gr_t in
      *"$2"*) GR=$GR${gr_t%%"$2"*}$3; gr_t=${gr_t#*"$2"} ;;
      *) GR=$GR$gr_t; return 0 ;;
    esac
  done
}

# g_refs <text>: GR = text with each {NAME} of an earlier block line replaced by its
# value (kept in the variable GV_NAME, set by g_load: a lookup is one eval, not a scan
# of the whole block); a {NAME} that is not a block line (a selector) is kept as is.
g_refs() {
  GR=""; gf_t=$1
  while :; do
    case $gf_t in
      *"{"*) ;;
      *) GR=$GR$gf_t; return 0 ;;
    esac
    GR=$GR${gf_t%%"{"*}; gf_t=${gf_t#*"{"}
    case $gf_t in *"}"*) gf_k=${gf_t%%"}"*} ;; *) gf_k="" ;; esac
    case $gf_k in
      ''|[!A-Z]*|*[!A-Z0-9_]*) GR=$GR"{"; continue ;;
    esac
    gf_s=""; gf_v=""
    # gf_k holds only [A-Z0-9_] (checked above); the value is assigned by indirection and
    # never evaluated
    eval "gf_s=\${GV_$gf_k+x}"
    if [ "$gf_s" = x ]; then
      eval "gf_v=\$GV_$gf_k"; GR=$GR$gf_v; gf_t=${gf_t#*"}"}
    else
      GR=$GR"{"
    fi
  done
}

# g_tr <text>: GR = text with the placeholders in their POSIX ERE spelling (raw bytes;
# <BS> is a backslash inside brackets). Run on the short source line, before references
# are expanded, so a long expanded line is never scanned.
g_tr() {
  case $1 in *"<"*) ;; *) GR=$1; return 0 ;; esac
  g_rep "$1" "<TAB>" "$TAB"; g_rep "$GR" "<BS>" '\'; g_rep "$GR" "<HI>" "$HI0-$HI1"
  g_rep "$GR" "<CURLY>" "${CU0}[$CU1-$CU7]"; g_rep "$GR" "<Q>" "'"; g_rep "$GR" "<CR>" "$CR"
  g_rep "$GR" "<SOH>" "$SOH"; g_rep "$GR" "<L>" "$M_L"; g_rep "$GR" "<R>" "$M_R"
}

# g_load <1|0>: GV_NAME = the line's value, placeholders translated and references
# expanded, in block order (a reference sees earlier lines only);
# 1 keeps only the S.1 lines (S1_*, W_*, which refer to no other line): the hot path.
g_load() {
  # an inherited GV_X_CD/GV_X_VF/GV_HL/GV_HS/GV_BL/GV_BS must never reach g_refs
  unset GV_X_CD GV_X_VF GV_HL GV_HS GV_BL GV_BS
  gl_rest=$G_DEFS
  while [ -n "$gl_rest" ]; do
    gl_ln=${gl_rest%%"$NL"*}
    case $gl_rest in *"$NL"*) gl_rest=${gl_rest#*"$NL"} ;; *) gl_rest="" ;; esac
    case $gl_ln in ''|'#'*) continue ;; esac
    gl_n=${gl_ln%%=*}; gl_v=${gl_ln#*=}
    if [ "$1" = 1 ]; then
      case $gl_n in S1_*|W_*) ;; *) continue ;; esac
    fi
    g_tr "$gl_v"; gl_v=$GR
    case $gl_v in *"{"*) g_refs "$gl_v"; gl_v=$GR ;; esac
    # gl_n holds only [A-Z0-9_] (a block line name); the value is assigned, never evaluated
    case $gl_n in *[!A-Z0-9_]*) continue ;; esac
    eval "GV_$gl_n=\$gl_v"
  done
}

# g_get <NAME>: GV = the expanded line. A missing line is an internal error: the
# caller's stage rule applies (tool failure).
g_get() {
  case $1 in ''|*[!A-Z0-9_]*) GV=""; return 1 ;; esac
  gg_s=""
  eval "gg_s=\${GV_$1+x}"
  if [ "$gg_s" = x ]; then eval "GV=\$GV_$1"; return 0; fi
  GV=""; return 1
}

# --- candidate test (S.1, T.2) ------------------------------------------------
sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9_-')
[ -n "$sid" ] || exit 0
# ${#cmd} counts bytes: LC_ALL=C is exported at hook start (bash 3.2 included)
big=0
[ "${#cmd}" -gt 65536 ] && big=1
# s1_fail: a failing S.1 tool keeps S.1's rule: over the cap W_SIZE, else exit 0
s1_fail() {
  [ "$big" = 1 ] && deny "$K_ANY" "$W_SIZE" "$T_ANY"
  exit 0
}
g_load 1
g_get S1_JOIN || s1_fail; s1_join=$GV
g_get S1_CURLY || s1_fail; s1_curly=$GV
g_get S1_DQ || s1_fail; s1_dq=$GV
g_get S1_BRACE1 || s1_fail; s1_b1=$GV
g_get S1_BRACE2O || s1_fail; s1_b2o=$GV
g_get S1_BRACE2C || s1_fail; s1_b2c=$GV
g_get S1_BRACE3V || s1_fail; s1_b3v=$GV
g_get S1_BRACE3O || s1_fail; s1_b3o=$GV
g_get S1_SUBST || s1_fail; s1_subst=$GV
g_get S1_BTICK || s1_fail; s1_btick=$GV
g_get S1_PARAM || s1_fail; s1_param=$GV
g_get S1_QUOTES || s1_fail; s1_q=$GV
g_get S1_STASH || s1_fail; s1_st=$GV

# CAND: (W_GIT and W_PUSH) or (W_GH and W_PRMR and W_CRNEW) on one line, as the
# orderings of the words with a separator between them (a DFA in grep; the .ps1
# runs the five word tests separately, the language is the same). s1_atom splits a
# W_ line (lead)WORD(SEP|$) into AW = WORD and AS = SEP.
s1_lead='(^|[^A-Za-z0-9])'
s1_atom() {
  g_get "$1" || s1_fail
  case $GV in "$s1_lead"*'|$)') ;; *) s1_fail ;; esac
  sa_w=${GV#"$s1_lead"}; sa_s=${sa_w##*"("}
  AW=${sa_w%"($sa_s"}; AS=${sa_s%'|$)'}
}
s1_atom W_GIT; a_git=$AW; s_git=$AS
s1_atom W_PUSH; a_push=$AW; s_push=$AS
s1_atom W_GH; a_gh=$AW; s_gh=$AS
s1_atom W_PRMR; a_prmr=$AW; s_prmr=$AS
s1_atom W_CRNEW; a_crnew=$AW; s_crnew=$AS
s1_gap="([^$ETX]*[^A-Za-z0-9])?"
cand="$s1_lead$a_git$s_git$s1_gap$a_push($s_push|\$)|$s1_lead$a_push$s_push$s1_gap$a_git($s_git|\$)"
for s1_o in "gh prmr crnew" "gh crnew prmr" "prmr gh crnew" "prmr crnew gh" "crnew gh prmr" "crnew prmr gh"; do
  s1_t=$s1_lead; s1_k=0
  for s1_w in $s1_o; do
    s1_k=$((s1_k + 1))
    case $s1_w in
      gh) s1_a=$a_gh; s1_s=$s_gh ;;
      prmr) s1_a=$a_prmr; s1_s=$s_prmr ;;
      *) s1_a=$a_crnew; s1_s=$s_crnew ;;
    esac
    if [ "$s1_k" = 3 ]; then s1_t=$s1_t$s1_a"($s1_s|\$)"; else s1_t=$s1_t$s1_a$s1_s$s1_gap; fi
  done
  cand="$cand|$s1_t"
done

# Four spellings (h/g/p in one sed; T.2, T.11b), each twice (T.11a): the text goes in as
# two lines, line 1 with each continuation pair deleted and line 2 with each pair read as
# one space. Then one sentinel line (on the last input line) that always matches: a count
# below 1 means a tool failed. CR stays a byte; LF becomes SOH; SOH and ETX become STX
# (ETX is the any-byte class). The CRLF translation of jq on Windows was undone above (T.11e).
s1_x=$(printf '%s' "$cmd" | tr '\012\001\003' '\001\002\002')
n1=$(printf '%s\n%s\n' "$s1_x" "$s1_x" | sed -n -E \
  -e "1s/$s1_join//g" -e "2s/$s1_join/ /g" -e "s/$s1_curly//g" -e "s/$s1_dq//g" -e h \
  -e "s/$s1_b1//g" -e "s/$s1_q//g" -e "s/$s1_st/\\1PUSH/" -e p -e g \
  -e "s/$s1_b2o//g" -e "s/$s1_b2c//g" -e "s/$s1_q//g" -e "s/$s1_st/\\1PUSH/" -e p -e g \
  -e "s/$s1_b3v//g" -e "s/$s1_b3o//g" -e "s/$s1_b2c//g" -e "s/$s1_q//g" -e "s/$s1_st/\\1PUSH/" -e p -e g \
  -e "s/$s1_b1//g" -e "s/$s1_subst//g" -e "s/$s1_btick//g" -e "s/$s1_param//g" -e "s/$s1_q//g" -e "s/$s1_st/\\1PUSH/" -e p \
  -e "\$s/^[^$ETX]*\$/git push/" -e '$p' 2>/dev/null | grep -a -c -E -e "$cand" 2>/dev/null)
case $n1 in
  ''|*[!0-9]*|0) s1_fail ;;
  1) exit 0 ;;
esac
[ "$big" = 1 ] && deny "$K_ANY" "$W_SIZE" "$T_ANY"
chk_time

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

# --- FORM (T.3) ---------------------------------------------------------------
# Any failure from here to the fields (a tool, a missing grammar line) denies W_PLAIN.
g_load 0
if [ "$dialect_ps" = 1 ]; then g_get P_FORM || not_plain; else g_get B_FORM || not_plain; fi
g_form=$GV
tcmd=$cmd
if [ "$dialect_ps" = 1 ]; then
  # curly quotes are quotes in the PowerShell dialect: U+2018-U+201B to ', U+201C-U+201E to "
  tcmd=$(printf '%s' "$cmd" | sed -e "s/${CU0}[$CU1-$CU4]/'/g" -e "s/${CU0}[$CU5-$CU7]/\"/g" 2>/dev/null) || not_plain
fi
body=$(printf '%s' "$tcmd" | tr '\001\015\012' '\002\001\001' 2>/dev/null) || not_plain
[ -n "$body" ] || not_plain
printf '%s\n' "$body" | grep -a -E -q -e "$g_form" 2>/dev/null || not_plain

# --- token stage (T.4) --------------------------------------------------------
# One sed -E. Output: kind US op US loc US sub US flags US a1 US a2 (push) or
# kind US op US loc US sub US flags US a1 NL a2 (PR); flags N dry run, D delete,
# T --tags, X not plain. The header STRUCT is applied without its create|new tail,
# which only a gh/glab header takes (git push create main keeps create as its
# remote): sub is push, or pr+ / mr+ once create|new is read.
g_get LEX || not_plain; ts_lex=$GV
g_get T || not_plain; ts_t=$GV
g_get STRUCT || not_plain; ts_st=$GV
if [ "$dialect_ps" = 1 ]; then g_get P_CD || not_plain; else g_get B_CD || not_plain; fi
g_rep "$ts_st" "{X_CD}" "$GV"; ts_st=$GR
ts_suf="($M_L""W(create|new)$M_R)?"
ts_pre=${ts_st%"$ts_suf"}
[ "$ts_pre" != "$ts_st" ] || not_plain
# P_CD holds one group, so the groups shift by one in the PowerShell dialect
if [ "$dialect_ps" = 1 ]; then
  ts_hdr="$M_K\\5$M_H\\4\\7$M_J\\3\\8$M_K\\9$M_Z"
else
  ts_hdr="$M_K\\4$M_H\\3\\6$M_J\\2\\7$M_K\\8$M_Z"
fi
# T.11(c): in the PowerShell dialect a --% word is not plain (the rest of the line would
# reach the program raw, unread): the line becomes the bare K marker, which the field check
# below denies. Bash reads --% as a literal word: its pattern is a word that cannot occur.
if [ "$dialect_ps" = 1 ]; then ts_pct='--%'; else ts_pct=$M_K; fi
g_get PUSHARG || not_plain; ts_pa=$GV
g_get ALPHA || not_plain; ts_al=$GV
ts_p2=""
# PowerShell: an option value is held to the push alphabet (S.3-bis c)
[ "$dialect_ps" = 1 ] && ts_p2="/$M_V$ts_al*[^%+-:=@-Z_a-z$M_VE]/s/$M_Z/${M_Z}X/$NL"
ts_push="/^${M_K}git$M_H/{
s/$ts_pa/$M_V\\1\\3$M_VE$M_F\\5$M_FE/g
$ts_p2/$M_F(-n|--dry-run)$M_FE/s/$M_Z/${M_Z}N/
/$M_F(-d|--delete)$M_FE/s/$M_Z/${M_Z}D/
/$M_F--tags$M_FE/s/$M_Z/${M_Z}T/
s/${M_V}[^$M_VE]*$M_VE${M_F}[^$M_FE]*$M_FE//g
/${M_L}O/s/$M_Z/${M_Z}X/
/${M_L}W-|${M_L}W$M_R|$ts_t$ts_t$M_L/s/$M_Z/${M_Z}X/
s/^$M_K([^$M_H]*)$M_H([^$M_J]*)$M_J([^$M_K]*)$M_K([^$M_Z]*)$M_Z([NDTX]*)($ts_t)?($ts_t)?\$/\\1$US\\2$US\\3$US\\4$US\\5$US\\7$US\\9/
}"
g_get PR1 || not_plain; ts_r1=$GV
g_get PR2 || not_plain; ts_r2=$GV
g_get GH_VF || not_plain; ts_ghvf=$GV
g_get GL_VF || not_plain; ts_glvf=$GV
# ts_prblock <kind> <head long> <head short> <base long> <base short> <value-taking list>
ts_prblock() {
  g_rep "$ts_r1" "{HL}" "$2"; g_rep "$GR" "{HS}" "$3"; g_rep "$GR" "{BL}" "$4"; g_rep "$GR" "{BS}" "$5"
  g_rep "$GR" "{X_VF}" "$6"; tp_1=$GR
  g_rep "$ts_r2" "{HL}" "$2"; g_rep "$GR" "{BL}" "$4"; tp_2=$GR
  # value-taking options consume the next word first, then the single-word rules;
  # the last --head / --base wins: one anchored match each (hold space)
  TP="/^$M_K$1$M_H/{
s/$tp_1/$M_S\\1$M_SV\\3$M_SE$M_DD\\4$M_DV\\6$M_DE/g
s/$tp_2/$M_S\\1$M_SV\\2$M_SE$M_DD\\3$M_DV\\4$M_DE$M_N\\5$M_NE$M_X\\6$M_XE/g
s/$M_S$M_SV$M_SE//g
s/$M_DD$M_DV$M_DE//g
s/$M_N$M_NE//g
s/$M_X$M_XE//g
/${M_X}[^$M_XE]+$M_XE/s/$M_Z/${M_Z}X/
/$M_N--dry-run$M_NE/s/$M_Z/${M_Z}N/
/${M_L}O/s/$M_Z/${M_Z}X/
h
s/^(${M_K}[^$M_Z]*${M_Z}[NX]*)([^$ETX]*${M_S}[^$M_SV]*$M_SV([^$M_SE]*)$M_SE)?[^$M_S]*\$/\\1$US\\3/
x
s/^([^$ETX]*${M_DD}[^$M_DV]*$M_DV([^$M_DE]*)$M_DE)?[^$M_DD]*\$/\\2/
x
G
s/^$M_K([^$M_H]*)$M_H([^$M_J]*)$M_J([^$M_K]*)$M_K([^$M_Z]*)$M_Z([NX]*)/\\1$US\\2$US\\3$US\\4$US\\5/
}"
}
ts_prblock gh --head -H --base -B "$ts_ghvf"; ts_gh=$TP
ts_prblock glab --source-branch -s --target-branch -b "$ts_glvf"; ts_gl=$TP

# lexer: joiner, redirection operator, blank run, quoted strings; then W/O tokens.
# Leading and trailing blank runs go before the quote markers do, so a trailing empty
# quoted word ("") stays an (empty) token.
f=$(printf '%s\n' "$body" | sed -E \
  -e "s/$ts_lex/$M_A\\1$M_B\\4$M_C\\5\\6$M_D\\2$M_E/g" \
  -e "s/$M_A$M_B$M_C${M_D}[0-9*]?>[^$STX]*\$//" \
  -e "s/$M_A(&&|;)$M_B$M_C$M_D$M_E/$M_R${M_L}O\\1$M_R${M_L}W/g" \
  -e "s/$M_A${M_B}[ $TAB$SOH]+$M_C$M_D$M_E/$M_R${M_L}W/g" \
  -e "s/^$M_R${M_L}W//" -e "s/$M_R${M_L}W\$//" \
  -e "s/$M_A$M_B$M_C//g" -e "s/$M_D$M_E//g" \
  -e "s/^/${M_L}W/" -e "s/\$/$M_R/" \
  -e "/${M_L}W${ts_pct}${M_R}/s/.*/$M_K/" \
  -e "s/$ts_pre/$ts_hdr/" \
  -e "s/^($M_K(gh|glab)${M_H}[^$M_K]*$M_K(pr|mr))$M_Z${M_L}W(create|new)$M_R/\\1+$M_Z/" \
  -e "$ts_push" -e "$ts_gh" -e "$ts_gl" 2>/dev/null) || not_plain
chk_time

# --- fields -------------------------------------------------------------------
case $f in *"$M_K"*|*"$M_H"*|*"$M_J"*|*"$M_Z"*|*"$M_L"*|*"$M_R"*) not_plain ;; esac
# fld: FV = the next US-separated field of f; a missing separator is not plain
fld() {
  case $f in *"$US"*) FV=${f%%"$US"*}; f=${f#*"$US"} ;; *) not_plain ;; esac
}
fld; kind=$FV
fld; op=$FV
fld; loc=$FV
fld; sub=$FV
fld; flags=$FV
case $kind in
  git)
    [ "$sub" = push ] || not_plain
    fld; a1=$FV; a2=$f
    case $a2 in *"$US"*|*"$NL"*) not_plain ;; esac ;;
  gh|glab)
    if [ "$kind" = gh ]; then [ "$sub" = pr+ ] || not_plain; else [ "$sub" = mr+ ] || not_plain; fi
    case $f in
      *"$NL"*) a1=${f%%"$NL"*}; a2=${f#*"$NL"} ;;
      *) a1=$f; a2="" ;;
    esac
    case $a1$a2 in *"$US"*|*"$NL"*) not_plain ;; esac ;;
  *) not_plain ;;
esac
# a location prefix and -C together, an unread option, an O joiner among the words
case $op in ''|'&&'|';'|-C) ;; *) not_plain ;; esac
case $flags in *X*) not_plain ;; esac
has_loc=0
[ -n "$op" ] && has_loc=1

# --- post-checks on the location (T.5) ----------------------------------------
if [ "$has_loc" = 1 ]; then
  [ -n "$loc" ] || not_plain
  # 3-bis e, n: a Bash directory beginning with ~ is plain only when its raw text
  # begins ~/ or is ~ (a quoted tilde is not expanded by the shell): TILDE
  if [ "$dialect_ps" = 0 ]; then
    case $loc in
      "~"*)
        g_get TILDE || not_plain
        printf '%s\n' "$body" | grep -a -E -q -e "$GV" 2>/dev/null || not_plain ;;
    esac
  fi
  # option-looking, UNC/network (decided before any filesystem access) and ~user
  # are not plain
  # shellcheck disable=SC2088
  case $loc in
    [A-Za-z]:|[A-Za-z]:[!/\\]*) not_plain ;;
    \\[!\\/]*|\\) not_plain ;;
    -*|//*|\\\\*|/\\*|\\/*) not_plain ;;
    "~"|"~/"*|"~\\"*) ;;
    "~"*) not_plain ;;
  esac
  # the MSYS drive form /c/... is Bash-dialect only (S.3-bis m)
  if [ "$dialect_ps" = 1 ]; then
    case $loc in /*) not_plain ;; esac
  fi
fi
chk_time

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

# --- git push (S.2 option allowlist read by the token stage, S.4 decision) ----
# $1 $2: the positionals (remote, refspec); $3 flags: N dry run, D delete, T --tags.
do_push() {
  dry=0; del=0; tags=0; all=0; mirror=0; remote=$1; refs=$2
  case $3 in *N*) dry=1 ;; esac
  case $3 in *D*) del=1 ;; esac
  case $3 in *T*) tags=1 ;; esac
  # S.2 quoting never relaxes the plain form: after unquoting, the remote and the
  # refspec must still be literal names (a quoted wildcard or space is not plain).
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

# --- gh pr create|new / glab mr create|new ------------------------------------
# $1 $2: the last --head / --base (--source-branch / --target-branch) values;
# $3 flags: N --dry-run.
do_pr() {
  if [ "$kind" = glab ]; then pr_label="glab mr create"; else pr_label="gh pr create"; fi
  pr_src=$1; pr_dst=$2
  case $3 in *N*) exit 0 ;; esac
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

if [ "$kind" = git ]; then do_push "$a1" "$a2" "$flags"; else do_pr "$a1" "$a2" "$flags"; fi
