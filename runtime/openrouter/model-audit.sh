#!/usr/bin/env bash
# tools/launch/model-audit.sh
#
# Which model is THIS session actually running on, and what would each
# alias resolve to? Answers from the environment — the durable version is
# OTel claude_code.llm_request (model, agent.name) against local Tempo; the
# JSONL transcript is documented as internal and is not parsed.
#
#   tools/launch/model-audit.sh
#
# Prints: the effective provider variables, the four alias pins, the
# session model, and how to read back what was actually SERVED (OpenRouter
# /generation, the Activity page) — because configured and served can
# differ, and the served model is the only ground truth.
set -uo pipefail

say() { printf '%s\n' "$*"; }

say "== provider variables in this session's environment =="
found=0
# ALLOWLIST, not denylist: the audit interprets a closed set — the alias
# pins, the session pins, the routing URL — and for every other provider
# variable the only fact it needs is set / not set. The first version
# redacted two names and printed the rest verbatim, so a credential in
# any other ANTHROPIC_* (ANTHROPIC_CUSTOM_HEADERS carrying an
# Authorization header, ANTHROPIC_FOUNDRY_API_KEY, whatever a proxy adds
# next) went into output written to be pasted into a PR thread (review
# on PR #679, judged CONFIRMED). Values that may carry a secret are never
# printed; an allowlist cannot be outgrown by a name nobody knew about.
# NUL-delimited records: `env | sort` line-splits a VALUE containing a
# newline, so a redacted variable whose tail read `\nANTHROPIC_MODEL=…`
# printed that tail verbatim under an allowlisted name, and its byte
# count stopped at the newline (review on PR #679, judged CONFIRMED).
while IFS= read -r -d '' kv; do
    k="${kv%%=*}"; v="${kv#*=}"
    [[ "$k" == ANTHROPIC_* || "$k" == CLAUDE_CODE_SUBAGENT_MODEL ]] || continue
    [[ -n "$v" ]] || continue
    found=1
    case "$k" in
        ANTHROPIC_DEFAULT_HAIKU_MODEL|ANTHROPIC_DEFAULT_SONNET_MODEL|ANTHROPIC_DEFAULT_OPUS_MODEL|ANTHROPIC_DEFAULT_FABLE_MODEL|ANTHROPIC_MODEL|ANTHROPIC_SMALL_FAST_MODEL|CLAUDE_CODE_SUBAGENT_MODEL)
            say "  $k = $v" ;;
        ANTHROPIC_BASE_URL)
            # scheme://host[:port] only, PARSED, failing closed: a base URL can
            # carry userinfo, a query or a fragment, and the sed that preceded
            # this printed every shape it did not match verbatim — an uppercase
            # scheme, `?api_key=` with no path (review on PR #679, judged
            # CONFIRMED). Not a URL at all: reported set, never echoed.
            say "  $k = $(python3 - "$v" <<'PY'
import sys
from urllib.parse import urlsplit
v = sys.argv[1]
try:
    u = urlsplit(v); host, port = u.hostname, u.port
except ValueError:
    u = host = port = None
if u is not None and u.scheme and host:
    print("%s://%s%s" % (u.scheme, host, ":%d" % port if port else ""))
else:
    print("<set, %d chars>" % len(v))
PY
)" ;;
        *)
            say "  $k = <set, $(printf '%s' "$v" | wc -c) chars>" ;;
    esac
done < <(env -0 | sort -z)
(( found )) || say "  (none set — a vanilla Anthropic-routed launch, or variables not exported here)"

say ""
say "== the launcher's stamp (tools/launch/ori) =="
# The session model reaches claude only as --model, which nothing inside
# the session can read back; the launcher stamps what it applied.
if [[ -n "${GZAPP_LAUNCH_SESSION_MODEL:-}" ]]; then
    say "  profile : ${GZAPP_LAUNCH_PROFILE:-?}"
    say "  session : $GZAPP_LAUNCH_SESSION_MODEL"
else
    say "  not launched via tools/launch/ori — the session model is the harness"
    say "  default or a settings-scope \"model\" key, and is not visible from the"
    say "  environment. /status inside the session shows it."
fi

say ""
say "== the four alias pins (ANTHROPIC_DEFAULT_*) =="
for tier in HAIKU SONNET OPUS FABLE; do
    var="ANTHROPIC_DEFAULT_${tier}_MODEL"
    printf '  %-10s %s\n' "${tier,,}" "${!var:-<unset — harness default>}"
done

say ""
say "== how to read back what was actually SERVED =="
# Classified on the PARSED hostname, case-insensitively, exact or a
# subdomain of openrouter.ai (the host the ori broker exports): the
# substring test called HTTPS://OPENROUTER.AI vanilla and a look-alike
# with "openrouter" in its path OpenRouter (review on PR #679).
OR_HOST="$(python3 -c 'import sys
from urllib.parse import urlsplit
try: h = urlsplit(sys.argv[1]).hostname or ""
except ValueError: h = ""
print(int(h == "openrouter.ai" or h.endswith(".openrouter.ai")))' "${ANTHROPIC_BASE_URL:-}")"
if [[ "$OR_HOST" == 1 ]]; then
    say "  This session is routed through OpenRouter. After a request:"
    say "    GET https://openrouter.ai/api/v1/generation?id=<generation id>"
    say "  ...or the Activity page; response 'model'/'provider' name the model"
    say "  that ACTUALLY served the request. Configured and served can differ"
    say "  (router fallback); the response is the ground truth."
else
    say "  ANTHROPIC_BASE_URL does not name OpenRouter in this environment —"
    say "  this reads as a vanilla Anthropic-routed session."
fi
say ""
say "  The durable path: OTel claude_code.llm_request (model, agent.name)"
say "  against local Tempo — per-request, per-agent, no transcript parsing."
say "  (The transcript JSONL is documented as internal; do not parse it.)"
