#!/usr/bin/env bash
# Runs Sirius's real launch arguments against released Claude Code and Codex
# CLIs, so a flag or field an older CLI lacks is caught before a DMG ships
# (on Claude Code 2.1.212 Sirius could not start at all:
# "unknown option '--system-prompt-snapshot'").
#
#   scripts/compat-test.sh                 the default versions below
#   CLAUDE_VERSIONS="2.1.71 latest" CODEX_VERSIONS="0.159.1" scripts/compat-test.sh
#
# Each version is installed from npm into a temp prefix (deleted afterwards),
# with HOME, CLAUDE_CONFIG_DIR and CODEX_HOME pointed at temp folders, so the
# user's own config is never read or written. No prompt is sent and no
# account is needed: no tokens are spent.
#
# The arguments come from Sirius itself (`Sirius --print-agent-args`,
# Sources/SiriusAdapters/AgentArgsPreview.swift), not from a copy here.
#
#   Claude: Sirius probes the CLI as it would at start. If it would launch,
#     the CLI is run with that argv and stdin closed: Commander rejects an
#     unknown option or choice before anything else runs, and with no input
#     a CLI that parsed exits 0 without calling the API. A version in
#     CLAUDE_OLD must instead get Sirius's "too old" refusal.
#   Codex: Sirius probes `codex --version` as it would at start. If it would
#     launch, `codex app-server` is run with Sirius's argv (without the
#     features.multi_agent_v2 settings before 0.147.0), then initialize and
#     the exact thread/start Sirius sends (no turn, so no model call). Also
#     run with --strict-config, which fails on a -c key the version would
#     ignore in silence, and the JSON schema the CLI generates is checked for
#     every method Sirius calls, every thread/start and turn/start field it
#     sends (app-server ignores unknown fields) and each input item type. A
#     version in CODEX_OLD must instead get Sirius's "too old" refusal.
#
# Before any downloaded binary runs it must pass codesign --verify --strict,
# spctl (a Developer ID origin; a bare CLI is "not an app" to spctl), carry a
# signing timestamp, and be absent from Gatekeeper's blocklist (gk.db). One
# that fails is a SKIP, never run; macOS blocked old OpenAI-signed codex
# builds as malware (0.130.0, 2026.10.12). Quarantine and provenance are
# never touched.
#
# Env:
#   SIRIUS_BIN        the Sirius binary to ask (default: a debug swift build)
#   CLAUDE_VERSIONS   must launch  (default: the floor, 2.1.212, latest)
#   CLAUDE_OLD        must be refused as too old (default: 2.1.70)
#   CODEX_VERSIONS    must launch  (default: the floor, 0.146.1, the last
#                     without the multi_agent_v2 settings, 0.147.0, 0.159.1,
#                     latest)
#   CODEX_OLD         must be refused as too old (default: 0.131.0, which
#                     macOS blocks, so a SKIP; and 0.1.2504301751, a
#                     TypeScript CLI with no app-server and no native binary,
#                     so one below the floor that passes the pre-check)
#   COMPAT_KEEP=1     keep the temp folder
# Exits non-zero on any FAIL. SKIP does not fail the run.

set -euo pipefail
cd "$(dirname "$0")/.."

# The oldest releases that support everything Sirius requires; README.md
# names the same numbers. Codex: the oldest release macOS still runs
# (0.131.0 and earlier are revoked or rejected by Gatekeeper, 2026.10.12),
# which passes every check here. CodexCapabilities.floor is the same.
CLAUDE_FLOOR=2.1.71
CODEX_FLOOR=0.132.0

CLAUDE_VERSIONS="${CLAUDE_VERSIONS-$CLAUDE_FLOOR 2.1.212 latest}"
CLAUDE_OLD="${CLAUDE_OLD-2.1.70}"
CODEX_VERSIONS="${CODEX_VERSIONS-$CODEX_FLOOR 0.146.1 0.147.0 0.159.1 latest}"
CODEX_OLD="${CODEX_OLD-0.131.0 0.1.2504301751}"

for tool in npm node python3 codesign spctl sqlite3; do
    command -v "$tool" >/dev/null || { echo "compat-test: needs $tool" >&2; exit 1; }
done

if [ -z "${SIRIUS_BIN:-}" ]; then
    echo "→ building Sirius (debug) for --print-agent-args"
    swift build --product SiriusApp >/dev/null
    swift build --product sirius-mcp >/dev/null
    SIRIUS_BIN="$(swift build --show-bin-path)/SiriusApp"
fi
[ -x "$SIRIUS_BIN" ] || { echo "compat-test: no Sirius binary at $SIRIUS_BIN" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sirius-compat.XXXXXX")"
if [ "${COMPAT_KEEP:-0}" != 1 ]; then trap 'rm -rf "$WORK"' EXIT; fi
mkdir -p "$WORK/home" "$WORK/root"
GKDB=/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Resources/gk.db
NODE_DIR="$(dirname "$(command -v node)")"
SAFE_PATH="$NODE_DIR:/usr/bin:/bin:/usr/sbin:/sbin"

ROWS=()
FAILED=0
row() { # cli version expect result detail
    ROWS+=("$(printf '%-7s %-28s %-7s %-5s %s' "$1" "$2" "$3" "$4" "$5")")
    [ "$4" = FAIL ] && FAILED=1
    return 0
}

# Prints why a Mach-O must not run, or nothing when it may.
precheck() {
    local bin="$1" info cdhash team assess
    codesign --verify --strict "$bin" 2>/dev/null || { echo "codesign --verify failed"; return; }
    assess="$(spctl -a -t exec -vv "$bin" 2>&1 || true)"
    if ! grep -q "accepted" <<<"$assess" \
        && ! grep -q "does not seem to be an app" <<<"$assess"; then
        echo "spctl: $(head -1 <<<"$assess")"; return
    fi
    grep -q "origin=Developer ID Application" <<<"$assess" || { echo "spctl: not Developer ID"; return; }
    info="$(codesign -dvvv "$bin" 2>&1)"
    grep -q "^Timestamp=" <<<"$info" || { echo "no signing timestamp"; return; }
    cdhash="$(sed -n 's/^CDHash=//p' <<<"$info" | head -1)"
    team="$(sed -n 's/^TeamIdentifier=//p' <<<"$info" | head -1)"
    if [ -r "$GKDB" ]; then
        if [ -n "$cdhash" ] && [ "$(sqlite3 "$GKDB" "select count(*) from blocked_hashes where hex(hash)=upper('$cdhash')")" != 0 ]; then
            echo "cdhash on Gatekeeper's blocklist"; return
        fi
        if [ -n "$team" ] && [ "$(sqlite3 "$GKDB" "select count(*) from blocked_teams where team_id='$team'")" != 0 ]; then
            echo "team $team on Gatekeeper's blocklist"; return
        fi
    fi
}

# The same for each Mach-O named <name>* under a folder: the binaries that
# run when the CLI starts. A package's vendored helpers (ripgrep) only run
# inside a turn, which this test never starts.
precheck_dir() { # folder name
    local f why
    while IFS= read -r f; do
        file -b "$f" | grep -q '^Mach-O' || continue
        why="$(precheck "$f")"
        if [ -n "$why" ]; then echo "$(basename "$f"): $why"; return; fi
    done < <(find "$1" -type f -name "$2*" -perm -u+x 2>/dev/null)
}

install() { # package version prefix → resolved version on stdout
    npm install --prefix "$3" --no-save --no-audit --no-fund --ignore-scripts --loglevel=error \
        "$1@$2" >/dev/null 2>&1 || return 1
    node -p "require('$3/node_modules/$1/package.json').version"
}

# MARK: Claude

claude_one() { # version expect(launch|tooOld)
    local v="$1" expect="$2" prefix="$WORK/claude-$1" real exe bin why preview outcome err status
    if ! real="$(install @anthropic-ai/claude-code "$v" "$prefix")"; then
        row claude "$v" "$expect" FAIL "npm install failed"; return
    fi
    # 2.1.110 and later ship a native binary in a platform package; older
    # ones are cli.js run by node.
    bin="$prefix/node_modules/@anthropic-ai/claude-code-darwin-$(uname -m)/claude"
    if [ -x "$bin" ]; then exe="$bin"; else exe="$prefix/node_modules/@anthropic-ai/claude-code/cli.js"; fi
    why="$(precheck_dir "$prefix/node_modules" claude)"
    if [ -n "$why" ]; then row claude "$real" "$expect" SKIP "blocked by macOS: $why"; rm -rf "$prefix"; return; fi
    local env=(env -i "PATH=$SAFE_PATH" "HOME=$WORK/home" "CLAUDE_CONFIG_DIR=$WORK/home/.claude"
               "TMPDIR=$WORK" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1)
    preview="$(cd "$WORK/root" && "${env[@]}" "$SIRIUS_BIN" --print-agent-args claude "$exe" "$WORK/root")"
    outcome="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["outcome"])' "$preview")"
    if [ "$outcome" = tooOld ]; then
        local msg; msg="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["message"])' "$preview")"
        if [ "$expect" = tooOld ]; then row claude "$real" "$expect" PASS "refused: $msg"
        else row claude "$real" "$expect" FAIL "Sirius refuses it: $msg"; fi
        rm -rf "$prefix"; return
    fi
    # Sirius would launch it: it must parse every flag.
    python3 -I -c 'import json,sys; print("\0".join(json.loads(sys.argv[1])["argv"]), end="")' "$preview" \
        > "$WORK/argv"
    local argv=(); while IFS= read -r -d '' a; do argv+=("$a"); done < <(cat "$WORK/argv"; printf '\0')
    set +e
    err="$(cd "$WORK/root" && "${env[@]}" perl -e 'alarm 60; exec @ARGV' "$exe" "${argv[@]}" </dev/null 2>&1 >/dev/null)"
    status=$?
    set -e
    local omitted=""
    for flag in --system-prompt-snapshot --effort --name --settings; do
        grep -qx -- "$flag" < <(tr '\0' '\n' < "$WORK/argv") || omitted+=" $flag"
    done
    if [ "$status" = 137 ] || [ "$status" = 9 ]; then
        row claude "$real" "$expect" SKIP "killed at launch (blocked by macOS?)"
    elif [ "$status" != 0 ] || grep -qiE "unknown option|error: option|invalid" <<<"$err"; then
        row claude "$real" "$expect" FAIL "exit $status: $(head -1 <<<"$err")"
    elif [ "$expect" = tooOld ]; then
        row claude "$real" "$expect" FAIL "Sirius launches it; expected the too-old refusal"
    else
        row claude "$real" "$expect" PASS "argv parses${omitted:+; left out:$omitted}"
    fi
    rm -rf "$prefix"
}

# MARK: Codex

codex_one() { # version expect
    local v="$1" expect="$2" prefix="$WORK/codex-$1" real bin why preview result
    if ! real="$(install @openai/codex "$v" "$prefix")"; then
        row codex "$v" "$expect" FAIL "npm install failed"; return
    fi
    # bin/codex.js execs the native binary from the platform package. The
    # TypeScript CLI (0.1.x) has none, and is only ever expected too old.
    bin="$(find "$prefix/node_modules/@openai" -path '*darwin*' -type f -name codex -perm -u+x 2>/dev/null | head -1)"
    if [ -z "$bin" ] && [ "$expect" != tooOld ]; then
        row codex "$real" "$expect" FAIL "no darwin binary in the package"; rm -rf "$prefix"; return
    fi
    why="$(precheck_dir "$prefix/node_modules" codex)"
    if [ -n "$why" ]; then row codex "$real" "$expect" SKIP "blocked by macOS: $why"; rm -rf "$prefix"; return; fi
    codex_check "$prefix/node_modules/.bin/codex" "$real" "$expect"
    rm -rf "$prefix"
}

scrub() { # dir: a straggler can still be writing into it, so retry
    local i
    for i in 1 2 3 4 5; do rm -rf "$1" 2>/dev/null && return; sleep 1; done
    rm -rf "$1" || true
}

codex_check() { # executable version expect
    local exe="$1" real="$2" expect="$3" preview result outcome msg
    mkdir -p "$WORK/codex-home"
    local env=(env -i "PATH=$SAFE_PATH" "HOME=$WORK/home" "CODEX_HOME=$WORK/codex-home" "TMPDIR=$WORK")
    # Sirius runs `codex --version` here, so in the same sealed environment.
    preview="$(cd "$WORK/root" && "${env[@]}" "$SIRIUS_BIN" --print-agent-args codex "$exe" "$WORK/root")"
    outcome="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["outcome"])' "$preview")"
    if [ "$outcome" = tooOld ]; then
        msg="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["message"])' "$preview")"
        if [ "$expect" = tooOld ]; then row codex "$real" "$expect" PASS "refused: $msg"
        else row codex "$real" "$expect" FAIL "Sirius refuses it: $msg"; fi
        scrub "$WORK/codex-home"; return
    fi
    if [ "$expect" = tooOld ]; then
        row codex "$real" "$expect" FAIL "Sirius launches it; expected the too-old refusal"
        scrub "$WORK/codex-home"; return
    fi
    set +e
    result="$("${env[@]}" python3 -I - "$exe" "$preview" "$WORK" <<'PY'
import json, os, select, subprocess, sys, tempfile, time, shutil
exe, preview, work = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
root = preview["threadStart"]["cwd"]
problems, notes = [], []

def run(argv):
    p = subprocess.Popen([exe] + argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, cwd=root, start_new_session=True)
    def stop():
        # The children of Codex (MCP servers, helpers) write into CODEX_HOME,
        # so end the whole group and let it settle before the folder goes.
        try:
            os.killpg(p.pid, 9)
        except ProcessLookupError:
            pass
        p.wait()
        time.sleep(0.3)
    def send(o):
        try:
            p.stdin.write((json.dumps(o) + "\n").encode()); p.stdin.flush()
        except BrokenPipeError:
            pass
    def wait(i, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([p.stdout], [], [], max(0, end - time.time()))
            if not r:
                break
            line = p.stdout.readline()
            if not line:
                err = p.stderr.read().decode(errors="replace").strip().splitlines()
                return {"exited": " / ".join(err[-2:]) or f"exit {p.wait()}"}
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("id") == i:
                return o
        return {"exited": "no answer in time"}
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": preview["initialize"]})
    r1 = wait(1)
    if "result" not in r1:
        stop()
        return "initialize: " + json.dumps(r1.get("error") or r1.get("exited"))[:200]
    send({"jsonrpc": "2.0", "method": "initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "thread/start", "params": preview["threadStart"]})
    r2 = wait(2)
    stop()
    if "result" not in r2:
        return "thread/start: " + json.dumps(r2.get("error") or r2.get("exited"))[:200]
    return None

argv = preview["argv"]
e = run(argv)
if e:
    problems.append(e)
else:
    helptext = subprocess.run([exe, "app-server", "--help"], capture_output=True, text=True).stdout
    if "--strict-config" in helptext:
        e = run([argv[0], "--strict-config"] + argv[1:])
        if e:
            problems.append("strict: " + e)
    else:
        notes.append("no --strict-config")
    d = tempfile.mkdtemp(dir=work)
    gen = subprocess.run([exe, "app-server", "generate-json-schema", "--out", d], capture_output=True, text=True)
    try:
        methods = []
        for v in json.load(open(os.path.join(d, "ClientRequest.json"))).get("oneOf", []):
            methods += v.get("properties", {}).get("method", {}).get("enum", [])
        missing = [m for m in preview["methods"] if m not in methods]
        if missing:
            problems.append("no method " + ", ".join(missing))
        v2 = json.load(open(os.path.join(d, "codex_app_server_protocol.v2.schemas.json")))
        defs = v2.get("definitions", v2.get("$defs", {}))
        for name, params in (("thread/start", "ThreadStartParams"), ("turn/start", "TurnStartParams")):
            props = defs.get(params, {}).get("properties", {})
            missing = [k for k in preview[name.replace("/s", "S")] if k not in props]
            if missing:
                problems.append(name + " ignores " + ", ".join(missing))
        types = [t for v in defs.get("UserInput", {}).get("oneOf", [])
                 for t in v.get("properties", {}).get("type", {}).get("enum", [])]
        missing = sorted({i["type"] for i in preview["turnStart"]["input"]} - set(types))
        if missing:
            problems.append("no input type " + ", ".join(missing))
    except (OSError, ValueError):
        notes.append("no schema")
    shutil.rmtree(d, ignore_errors=True)
if not preview.get("multiAgentSettings", True):
    notes.append("left out: features.multi_agent_v2")
print(("FAIL " + "; ".join(problems)) if problems else ("PASS app-server starts a thread" + ("; " + ", ".join(notes) if notes else "")))
PY
)"
    set -e
    row codex "$real" "$expect" "${result%% *}" "${result#* }"
    scrub "$WORK/codex-home"
}

resolve() { # package version → version (latest → the newest release)
    if [ "$2" = latest ]; then npm view "$1@latest" version; else echo "$2"; fi
}

for v in $CLAUDE_VERSIONS; do claude_one "$(resolve @anthropic-ai/claude-code "$v")" launch; done
for v in $CLAUDE_OLD; do claude_one "$v" tooOld; done
for v in $CODEX_VERSIONS; do codex_one "$(resolve @openai/codex "$v")" launch; done
for v in $CODEX_OLD; do codex_one "$v" tooOld; done
# The copy ChatGPT.app ships, which Sirius falls back to (CodexLaunch).
BUNDLED=/Applications/ChatGPT.app/Contents/Resources/codex-cli
if [ -x "$BUNDLED/bin/codex" ]; then
    label="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
        "$BUNDLED/codex-package.json" 2>/dev/null || echo '?') (ChatGPT.app)"
    why="$(precheck "$BUNDLED/CodexCLI.app")"
    if [ -n "$why" ]; then row codex "$label" launch SKIP "blocked by macOS: $why"
    else codex_check "$BUNDLED/bin/codex" "$label" launch; fi
fi

echo
printf '%-7s %-28s %-7s %-5s %s\n' CLI VERSION EXPECT RESULT DETAIL
for r in "${ROWS[@]}"; do echo "$r"; done
echo
if [ "$FAILED" = 1 ]; then echo "compat-test: FAIL"; exit 1; fi
echo "compat-test: pass"
