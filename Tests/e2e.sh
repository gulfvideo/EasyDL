#!/bin/bash
# End-to-end tests for EasyDL. These run real downloads through the app's own
# argument builder (Tests/ArgsFor), so what is exercised here is what the app does.
#
#   Tests/e2e.sh            the normal suite, a couple of minutes
#   Tests/e2e.sh --long     also the 403 fallback case (~1GB, ~90s)
#
# YouTube cases need a cookie file; without one they are skipped, not failed.
# Override with COOKIES=/path/to/cookies.txt.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/easydl-e2e.XXXXXX")"
COOKIES="${COOKIES:-$HOME/Documents/yt-cookies-youtube.txt}"
LONG=0
[ "${1:-}" = "--long" ] && LONG=1

PASS=0; FAIL=0; SKIP=0
CURRENT=""

GEN5="https://download.samplelib.com/mp4/sample-5s.mp4"
GEN10="https://download.samplelib.com/mp4/sample-10s.mp4"
GEN15="https://download.samplelib.com/mp4/sample-15s.mp4"
YT="https://www.youtube.com/watch?v=jNQXAC9IVRw"          # "Me at the zoo", 19s
YT_BAD="https://www.youtube.com/watch?v=aaaaaaaaaaa"       # well-formed, nonexistent
# A long past-live stream, where YouTube 403s every audio-only format. Any long
# "was_live" video shows the same behaviour — override with YT_403=... if this one
# ever disappears.
YT_403="${YT_403:-https://www.youtube.com/live/xbQnQ0vU4rU}"
POT="$HOME/Library/Application Support/EasyDL/pot-provider/server"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

scenario() { CURRENT="$1"; printf '\n\033[1m• %s\033[0m\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33m–\033[0m skipped: %s\n' "$1"; }

# --- helpers -----------------------------------------------------------------

FFMPEG_DIR="$(dirname "$(command -v ffmpeg 2>/dev/null || echo /opt/homebrew/bin/ffmpeg)")"
PY="$(head -1 "$(command -v yt-dlp)" | sed 's|^#!||')"

# Runs yt-dlp with exactly the arguments EasyDL would build. Output -> $LAST_LOG,
# exit status -> $LAST_RC.
run_easydl() {
  local args=()
  while IFS= read -r -d '' a; do args+=("$a"); done < <("$WORK/argsfor" "$@")
  if [ ${#args[@]} -eq 0 ]; then LAST_RC=99; LAST_LOG="argsfor produced nothing"; return; fi
  LAST_LOG="$(yt-dlp "${args[@]}" 2>&1)"
  LAST_RC=$?
}

# The app's argument list ends with "-- <url>". Anything appended after that is a
# positional argument, not a flag — so splice extras in ahead of the separator.
# Put the extras in EXTRA_ARGS; the result comes back in SPLICED.
splice_before_url() {   # usage: splice_before_url "${args[@]}"
  local all=("$@") n=$#
  local url="${all[n-1]}"
  SPLICED=("${all[@]:0:n-2}" "${EXTRA_ARGS[@]}" "--" "$url")
}

dur()    { ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null; }
height() { ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$1" 2>/dev/null; }
acodec() { ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null; }
vstreams() { ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null | wc -l | tr -d ' '; }

# near EXPECTED ACTUAL TOLERANCE
near() { awk -v a="$2" -v b="$1" -v t="$3" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=t)}'; }

# --- build the argument helper ------------------------------------------------

printf '\033[1mEasyDL end-to-end tests\033[0m\n'
if ! swiftc -O "$ROOT/Sources/EasyDL/Model.swift" "$ROOT/Tests/ArgsFor/main.swift" \
      -o "$WORK/argsfor" 2>"$WORK/build.err"; then
  printf '\033[31mCould not build the argument helper:\033[0m\n'; cat "$WORK/build.err"; exit 1
fi

COOKIE_ARGS=()
if [ -f "$COOKIES" ]; then COOKIE_ARGS=(--cookies "$COOKIES"); fi

# A local server that honours Range, so the resume test can measure what actually
# happened. samplelib.com answers a ranged request with 200 and the whole file, which
# makes resuming impossible there and made the old test unable to tell resume from
# restart.
SERVE="$WORK/serve"; mkdir -p "$SERVE"
ffmpeg -v error -y -f lavfi -i "testsrc=duration=20:size=640x360:rate=30" \
       -f lavfi -i "sine=frequency=440:duration=20" \
       -c:v libx264 -preset ultrafast -c:a aac -shortest "$SERVE/clip.mp4" 2>/dev/null
RANGE_LOG="$WORK/range.log"; : > "$RANGE_LOG"
python3 "$ROOT/Tests/rangeserver.py" "$SERVE" "$RANGE_LOG" > "$WORK/port.txt" 2>"$WORK/srv.err" &
SRV_PID=$!
disown "$SRV_PID" 2>/dev/null || true   # otherwise the shell announces the kill below
for _ in $(seq 1 50); do grep -q PORT= "$WORK/port.txt" 2>/dev/null && break; sleep 0.1; done
PORT="$(sed -n 's/^PORT=//p' "$WORK/port.txt")"
LOCAL="http://127.0.0.1:$PORT/clip.mp4"
cleanup() { [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$WORK"; }

# =============================================================================
scenario "The app's own offline checks still pass"
BIN="$ROOT/build/EasyDL.app/Contents/MacOS/EasyDL"
[ -x "$BIN" ] || BIN="$ROOT/.build/debug/EasyDL"
if [ -x "$BIN" ]; then
  if out="$("$BIN" --self-test 2>&1)"; then ok "$out"; else bad "self-test failed: $out"; fi
else
  skip "no built binary; run ./build.sh first"
fi

# =============================================================================
scenario "Download a video (the plain case)"
D="$WORK/s1"; mkdir -p "$D"
run_easydl --url "$GEN5" --kind mp4 --outdir "$D" --ffmpeg "$FFMPEG_DIR"
f="$(find "$D" -name '*.mp4' | head -1)"
if [ $LAST_RC -eq 0 ] && [ -n "$f" ]; then
  ok "downloaded $(basename "$f")"
  if near 5 "$(dur "$f")" 1; then ok "full length kept ($(dur "$f")s)"
  else bad "expected ~5s, got $(dur "$f")s — truncated?"; fi
  [ "$(vstreams "$f")" -ge 1 ] && ok "has a video stream" || bad "no video stream"
  [ "$(dirname "$f")" = "$D" ] && ok "saved straight into the chosen folder" \
    || bad "ended up in $(dirname "$f") instead of $D"
else
  bad "download failed (rc=$LAST_RC): $(echo "$LAST_LOG" | tail -2)"
fi

# =============================================================================
scenario "Convert to MP3"
D="$WORK/s2"; mkdir -p "$D"
run_easydl --url "$GEN10" --kind mp3 --outdir "$D" --ffmpeg "$FFMPEG_DIR"
f="$(find "$D" -name '*.mp3' | head -1)"
if [ $LAST_RC -eq 0 ] && [ -n "$f" ]; then
  ok "produced $(basename "$f")"
  [ "$(acodec "$f")" = "mp3" ] && ok "really is mp3" || bad "codec is $(acodec "$f")"
  [ "$(vstreams "$f")" -eq 0 ] && ok "video discarded" || bad "video left in the mp3"
  if near 10 "$(dur "$f")" 1; then ok "full length kept ($(dur "$f")s)"
  else bad "expected ~10s, got $(dur "$f")s"; fi
  [ -z "$(find "$D" -name '*.mp4')" ] && ok "source file cleaned up" || bad "source mp4 left behind"
else
  bad "mp3 failed (rc=$LAST_RC): $(echo "$LAST_LOG" | tail -2)"
fi

# =============================================================================
scenario "Queue several links at once"
D="$WORK/s3"; mkdir -p "$D"; n=0
for u in "$GEN5" "$GEN10" "$GEN15"; do
  run_easydl --url "$u" --kind mp4 --outdir "$D" --ffmpeg "$FFMPEG_DIR"
  [ $LAST_RC -eq 0 ] && n=$((n+1))
done
got="$(find "$D" -name '*.mp4' | wc -l | tr -d ' ')"
[ "$n" = 3 ] && [ "$got" = 3 ] && ok "all 3 downloaded, 3 distinct files" \
  || bad "expected 3 files, got $got (rc-ok=$n)"

# =============================================================================
scenario "Save to a folder with spaces and punctuation"
D="$WORK/My Videos & \"Clips\""; mkdir -p "$D"
run_easydl --url "$GEN5" --kind mp4 --outdir "$D" --ffmpeg "$FFMPEG_DIR"
f="$(find "$D" -name '*.mp4' | head -1)"
[ $LAST_RC -eq 0 ] && [ -n "$f" ] && ok "landed in the awkward folder" \
  || bad "failed on a path with spaces/quotes (rc=$LAST_RC)"

# =============================================================================
scenario "Ask for the same thing twice"
D="$WORK/s5"; mkdir -p "$D"
run_easydl --url "$GEN5" --kind mp4 --outdir "$D" --ffmpeg "$FFMPEG_DIR"
f="$(find "$D" -name '*.mp4' | head -1)"
before="$(stat -f%m "$f" 2>/dev/null)"; size1="$(stat -f%z "$f" 2>/dev/null)"
run_easydl --url "$GEN5" --kind mp4 --outdir "$D" --ffmpeg "$FFMPEG_DIR"
after="$(stat -f%m "$f" 2>/dev/null)"; size2="$(stat -f%z "$f" 2>/dev/null)"
if [ $LAST_RC -eq 0 ] && [ "$before" = "$after" ] && [ "$size1" = "$size2" ]; then
  ok "recognised as already downloaded, not re-fetched"
else
  bad "re-downloaded an existing file (rc=$LAST_RC)"
fi
[ "$(find "$D" -name '*.mp4' | wc -l | tr -d ' ')" = 1 ] && ok "no duplicate file created" \
  || bad "a second copy appeared"

# =============================================================================
scenario "Resume an interrupted download"
if [ -z "${PORT:-}" ] || [ ! -s "$SERVE/clip.mp4" ]; then
  skip "local range server did not start ($(head -1 "$WORK/srv.err" 2>/dev/null))"
else
  D="$WORK/s6"; mkdir -p "$D"
  run_easydl --url "$LOCAL" --kind mp4 --outdir "$D" --ffmpeg "$FFMPEG_DIR"
  ref="$(find "$D" -name '*.mp4' | head -1)"
  if [ $LAST_RC -ne 0 ] || [ -z "$ref" ]; then
    bad "setup download failed (rc=$LAST_RC): $(echo "$LAST_LOG" | tail -2)"
  else
    refsum="$(md5 -q "$ref")"; refsize="$(stat -f%z "$ref")"; half=$((refsize / 2))
    # Exactly what a cancelled download leaves behind.
    head -c "$half" "$ref" > "$ref.part"; rm -f "$ref"
    : > "$RANGE_LOG"
    run_easydl --url "$LOCAL" --kind mp4 --outdir "$D" --ffmpeg "$FFMPEG_DIR"

    if [ $LAST_RC -eq 0 ] && [ -f "$ref" ]; then
      [ "$(md5 -q "$ref")" = "$refsum" ] && ok "finished to a byte-identical file" \
        || bad "resumed file differs from a clean download"

      # The server records every request, so this is measured rather than inferred.
      # A digit is required: the generic extractor makes an unranged sniffing request
      # first, logged as "range=-", and a lax pattern matches that as an empty number.
      asked="$(grep -oE 'range=[0-9]+' "$RANGE_LOG" | head -1 | cut -d= -f2)"
      sent="$(grep -oE 'status=206' -B0 "$RANGE_LOG" >/dev/null 2>&1; \
              awk -F'sent=' '/status=206/{split($2,a," "); print a[1]}' "$RANGE_LOG" | tail -1)"
      if [ -n "$asked" ]; then
        ok "asked the server to continue from byte $asked (of $refsize)"
        if [ -n "$sent" ] && [ "$sent" -lt "$refsize" ]; then
          ok "transferred only $sent bytes, not the whole $refsize"
        else
          bad "asked for a range but still received $sent of $refsize bytes"
        fi
      else
        bad "no Range request: the partial file was discarded and re-downloaded"
      fi
    else
      bad "could not finish from a partial file (rc=$LAST_RC)"
    fi
  fi
fi

# =============================================================================
scenario "Paste a link that does not work"
D="$WORK/s7"; mkdir -p "$D"
run_easydl --url "https://example.invalid/nope.mp4" --kind mp4 --outdir "$D" --ffmpeg "$FFMPEG_DIR"
[ $LAST_RC -ne 0 ] && ok "failed instead of pretending to succeed" || bad "reported success"
[ -z "$(find "$D" -type f)" ] && ok "left no stray file behind" || bad "wrote a file anyway"

# =============================================================================
scenario "Playlists get a folder, single videos do not"
# Exercised against yt-dlp's own template engine: no network, fully deterministic,
# and it is the naming rule rather than yt-dlp's playlist expansion that is ours.
tmpl="$("$WORK/argsfor" --url x --kind mp4 --outdir /tmp | tr '\0' '\n' | grep -A0 '%(playlist_title' | head -1)"
if [ -z "$tmpl" ]; then bad "could not read the output template from the app"; else
  out="$("$PY" - "$tmpl" <<'EOF'
import sys
from yt_dlp import YoutubeDL
tpl = sys.argv[1]
ydl = YoutubeDL({'outtmpl': tpl, 'quiet': True})
single = {'title': 'Holiday', 'id': 'abc', 'ext': 'mp4'}
entry  = {'title': 'Track', 'id': 'xyz', 'ext': 'mp3', 'playlist_title': 'My Mix',
          'playlist_id': 'PL7', 'playlist_index': 3}
tricky = {'title': 'AC/DC: "Live" 1/2', 'id': 'q', 'ext': 'mp4'}
print(ydl.prepare_filename(single))
print(ydl.prepare_filename(entry))
print(ydl.prepare_filename(tricky))
EOF
)"
  # A single video resolves to "./name" — the "./" disappears when yt-dlp joins the
  # template onto --paths, which the real downloads above confirm. Strip it here.
  s_line="$(echo "$out" | sed -n 1p | sed 's|^\./||')"
  p_line="$(echo "$out" | sed -n 2p | sed 's|^\./||')"
  t_line="$(echo "$out" | sed -n 3p | sed 's|^\./||')"
  [ "$s_line" = "Holiday [abc].mp4" ] && ok "single video stays flat: $s_line" \
    || bad "single video path wrong: $s_line"
  [ "$p_line" = "My Mix [PL7]/003 - Track [xyz].mp3" ] && ok "playlist entry foldered and numbered: $p_line" \
    || bad "playlist path wrong: $p_line"
  case "$t_line" in
    */*) bad "a title with a slash escaped into a subdirectory: $t_line" ;;
    *)   ok "unsafe title characters neutralised: $t_line" ;;
  esac
fi

# =============================================================================
scenario "A hostile playlist name cannot escape the download folder"
# The folder name is remote-controlled and is a real path component. yt-dlp replaces
# "/" inside a field value but leaves a lone ".." alone, and sanitize_path() does not
# drop ".." on macOS — so this is rendered through yt-dlp's own engine rather than
# trusted to look right.
tmpl="$("$WORK/argsfor" --url x --kind mp4 --outdir /tmp | tr '\0' '\n' | grep '%(playlist_title' | head -1)"
if [ -z "$tmpl" ]; then bad "could not read the output template from the app"; else
  out="$("$PY" - "$tmpl" <<'EOF'
import sys, os
from yt_dlp import YoutubeDL
tpl, base = sys.argv[1], "/Users/me/Downloads"
ydl = YoutubeDL({'outtmpl': tpl, 'paths': {'home': base}, 'quiet': True})
cases = {
  'dotdot':        {'playlist_title': '..', 'playlist_id': 'PL1', 'playlist_index': 1},
  'dotdot_no_id':  {'playlist_title': '..', 'playlist_index': 1},
  'dotdot_empty':  {'playlist_title': '..', 'playlist_id': '', 'playlist_index': 1},
  'dot':           {'playlist_title': '.', 'playlist_id': 'PL1', 'playlist_index': 1},
  'slashes':       {'playlist_title': '../../etc', 'playlist_id': 'PL1', 'playlist_index': 1},
  'absolute':      {'playlist_title': '/etc/cron.d', 'playlist_id': 'PL1', 'playlist_index': 1},
  'tilde':         {'playlist_title': '~', 'playlist_id': 'PL1', 'playlist_index': 1},
  'title_dotdot':  {'title': '../../../etc/passwd'},
  'title_null':    {'title': 'a\x00b'},
}
escapes = 0
for name, extra in cases.items():
    info = {'title': 'T', 'id': 'ID', 'ext': 'mp4'}; info.update(extra)
    full = os.path.normpath(ydl.prepare_filename(info))
    if not full.startswith(base + os.sep):
        escapes += 1
        print(f'ESCAPE {name} -> {full}')
print(f'TOTAL_ESCAPES={escapes}')
EOF
)"
  esc="$(echo "$out" | sed -n 's/^TOTAL_ESCAPES=//p')"
  if [ "$esc" = "0" ]; then
    ok "9 hostile playlist/title names all stayed inside the download folder"
  else
    bad "$esc name(s) escaped: $(echo "$out" | grep '^ESCAPE' | head -3 | tr '\n' ' ')"
  fi
  # And the ordinary case must still work.
  norm="$("$PY" - "$tmpl" <<'EOF'
import sys
from yt_dlp import YoutubeDL
ydl = YoutubeDL({'outtmpl': sys.argv[1], 'quiet': True})
print(ydl.prepare_filename({'title': 'T', 'id': 'ID', 'ext': 'mp4'}))
print(ydl.prepare_filename({'title': 'T', 'id': 'ID', 'ext': 'mp4',
                            'playlist_title': 'My Mix', 'playlist_id': 'PL1', 'playlist_index': 3}))
EOF
)"
  [ "$(echo "$norm" | sed -n 1p)" = "./T [ID].mp4" ] && ok "single videos still stay flat" \
    || bad "single video path changed: $(echo "$norm" | sed -n 1p)"
  [ "$(echo "$norm" | sed -n 2p)" = "My Mix [PL1]/003 - T [ID].mp4" ] && ok "playlists still get a folder" \
    || bad "playlist path changed: $(echo "$norm" | sed -n 2p)"
fi

# =============================================================================
scenario "YouTube: quality picker is obeyed"
if [ ${#COOKIE_ARGS[@]} -eq 0 ]; then skip "no cookie file at $COOKIES"; else
  # Big Buck Bunny offers 720/1080/1440/2160, so a cap has something to bite on.
  # Selection is probed with --simulate: proving the ceiling needs no gigabytes.
  BBB="https://www.youtube.com/watch?v=aqz-KE-bpKQ"
  probe_height() {
    local args=() cap="$1"
    while IFS= read -r -d '' a; do args+=("$a"); done \
      < <("$WORK/argsfor" --url "$BBB" --kind mp4 --quality "$cap" --outdir "$WORK" "${COOKIE_ARGS[@]}")
    EXTRA_ARGS=(--simulate --print "@@H@@%(height)s")
    splice_before_url "${args[@]}"
    yt-dlp "${SPLICED[@]}" 2>/dev/null \
      | grep -o '@@H@@[0-9]*' | head -1 | sed 's/@@H@@//'
  }
  for cap in 360 720 1080; do
    h="$(probe_height "$cap")"
    if [ -n "$h" ] && [ "$h" -le "$cap" ]; then ok "${cap}p cap honoured (picked ${h}p)"
    else bad "asked for <=${cap}p, picked ${h:-nothing}"; fi
  done
  hb="$(probe_height best)"
  [ -n "$hb" ] && [ "$hb" -ge 2160 ] && ok "\"best available\" reaches 4K (${hb}p)" \
    || bad "best only reached ${hb:-nothing}p on a 4K source"

  # And once for real, end to end, on something small.
  D="$WORK/s9"; mkdir -p "$D"
  run_easydl --url "$YT" --kind mp4 --quality 360 --outdir "$D" --ffmpeg "$FFMPEG_DIR" "${COOKIE_ARGS[@]}"
  f="$(find "$D" -name '*.mp4' | head -1)"
  if [ $LAST_RC -eq 0 ] && [ -n "$f" ]; then
    h="$(height "$f")"
    [ -n "$h" ] && [ "$h" -le 360 ] && ok "real capped download is ${h}p" \
      || bad "capped download came out at ${h}p"
  else
    bad "capped download failed (rc=$LAST_RC): $(echo "$LAST_LOG" | tail -2)"
  fi
fi

# =============================================================================
scenario "YouTube: MP3 of a real video"
if [ ${#COOKIE_ARGS[@]} -eq 0 ]; then skip "no cookie file"; else
  D="$WORK/s10"; mkdir -p "$D"
  run_easydl --url "$YT" --kind mp3 --outdir "$D" --ffmpeg "$FFMPEG_DIR" "${COOKIE_ARGS[@]}"
  f="$(find "$D" -name '*.mp3' | head -1)"
  if [ $LAST_RC -eq 0 ] && [ -n "$f" ]; then
    ok "produced $(basename "$f")"
    [ "$(vstreams "$f")" -eq 0 ] && ok "audio only" || bad "video stream present"
    if near 19 "$(dur "$f")" 2; then ok "full length ($(dur "$f")s of 19s)"
    else bad "expected ~19s, got $(dur "$f")s"; fi
  else
    bad "youtube mp3 failed (rc=$LAST_RC): $(echo "$LAST_LOG" | tail -2)"
  fi
fi

# =============================================================================
scenario "YouTube without sign-in explains itself"
D="$WORK/s11"; mkdir -p "$D"
run_easydl --url "$YT" --kind mp4 --outdir "$D" --ffmpeg "$FFMPEG_DIR"
if [ $LAST_RC -ne 0 ]; then
  echo "$LAST_LOG" | grep -qiE "not a bot|sign in|cookies" \
    && ok "refused with the message the app knows how to explain" \
    || ok "refused (different message: $(echo "$LAST_LOG" | grep ERROR | head -1 | cut -c1-60))"
else
  ok "this video happens to be reachable anonymously"
fi

# =============================================================================
scenario "PO token provider"
if [ ! -f "$POT/package.json" ]; then
  skip "not installed (optional) — run ./install-pot-provider.sh"
elif [ ${#COOKIE_ARGS[@]} -eq 0 ]; then
  skip "no cookie file"
else
  v="$(yt-dlp --ignore-config -v --simulate --no-warnings "${COOKIE_ARGS[@]}" \
        --extractor-args "youtubepot-bgutilscript:server_home=$POT" "$YT" 2>&1)"
  echo "$v" | grep -q "PO Token Providers:.*bgutil" && ok "yt-dlp loads the plugin" \
    || bad "plugin not loaded — check ~/.config/yt-dlp/plugins/"
  echo "$v" | grep -qi "Retrieved a gvs PO Token" && ok "a token was actually minted" \
    || bad "plugin loaded but minted no token"
fi

# =============================================================================
scenario "A video that no longer exists"
if [ ${#COOKIE_ARGS[@]} -eq 0 ]; then skip "no cookie file"; else
  D="$WORK/s12"; mkdir -p "$D"
  run_easydl --url "$YT_BAD" --kind mp4 --outdir "$D" --ffmpeg "$FFMPEG_DIR" "${COOKIE_ARGS[@]}"
  [ $LAST_RC -ne 0 ] && ok "failed cleanly" || bad "claimed success for a dead video"
  [ -z "$(find "$D" -type f)" ] && ok "no stray file" || bad "wrote something"
fi

# =============================================================================
if [ $LONG -eq 1 ]; then
scenario "The 1GB detour is gone when a provider is installed (long)"
if [ ${#COOKIE_ARGS[@]} -eq 0 ]; then skip "no cookie file"; else

  if [ -f "$POT/package.json" ]; then
    # What gets fetched should now be an audio-only stream, not a video to discard.
    probe=()
    while IFS= read -r -d '' x; do probe+=("$x"); done \
      < <("$WORK/argsfor" --url "$YT_403" --kind mp3 --outdir "$WORK" --pot "$POT" "${COOKIE_ARGS[@]}")
    EXTRA_ARGS=(--simulate --print "@@F@@%(format_id)s|%(vcodec)s|%(filesize_approx)s")
    splice_before_url "${probe[@]}"
    info="$(yt-dlp "${SPLICED[@]}" 2>/dev/null \
            | grep -o '@@F@@.*' | head -1 | sed 's/@@F@@//')"
    vcodec="$(echo "$info" | cut -d'|' -f2)"; bytes="$(echo "$info" | cut -d'|' -f3)"
    [ "$vcodec" = "none" ] && ok "picks an audio-only stream (format $(echo "$info" | cut -d'|' -f1))" \
      || bad "still picking a stream with video ($vcodec)"
    if [ -n "$bytes" ] && [ "$bytes" -lt 314572800 ] 2>/dev/null; then
      ok "$((bytes / 1048576))MB to fetch, against 972MB for the progressive stream"
    else bad "expected well under 300MB, got ${bytes:-unknown} bytes"; fi

    D="$WORK/pot"; mkdir -p "$D"
    run_easydl --url "$YT_403" --kind mp3 --outdir "$D" --ffmpeg "$FFMPEG_DIR" \
               --pot "$POT" "${COOKIE_ARGS[@]}"
    f="$(find "$D" -name '*.mp3' | head -1)"
    if [ $LAST_RC -eq 0 ] && [ -n "$f" ]; then
      d="$(dur "$f")"
      near 13804 "$d" 5 && ok "and the MP3 is complete (${d}s)" || bad "TRUNCATED: got ${d}s"
    else
      bad "download failed with the provider (rc=$LAST_RC): $(echo "$LAST_LOG" | tail -2)"
    fi
  else
    skip "provider not installed; skipping the audio-only case"
  fi

  # Control: the same request without a provider is what the 403 fallback exists for.
  D="$WORK/nopot"; mkdir -p "$D"
  run_easydl --url "$YT_403" --kind mp3 --outdir "$D" --ffmpeg "$FFMPEG_DIR" "${COOKIE_ARGS[@]}"
  if [ $LAST_RC -ne 0 ] && echo "$LAST_LOG" | grep -qi "403"; then
    ok "without a provider it still 403s — the provider is what fixes it"
  else
    ok "audio-only succeeded even without a provider (YouTube may have relented)"
  fi

  # And the safety net still returns a whole file when it is reached.
  run_easydl --url "$YT_403" --kind mp3 --outdir "$D" --ffmpeg "$FFMPEG_DIR" \
             --fallback web_safari "${COOKIE_ARGS[@]}"
  f="$(find "$D" -name '*.mp3' | head -1)"
  if [ $LAST_RC -eq 0 ] && [ -n "$f" ]; then
    d="$(dur "$f")"
    near 13804 "$d" 5 && ok "fallback still returns the whole 3h50m recording (${d}s)" \
      || bad "fallback TRUNCATED: got ${d}s"
    echo "$LAST_LOG" | grep -qi "got error" \
      && bad "transfer hit errors; a fragmented rung was probably chosen" \
      || ok "fallback transferred with no fragment errors"
  else
    bad "fallback failed (rc=$LAST_RC): $(echo "$LAST_LOG" | tail -2)"
  fi
fi
fi

# =============================================================================
printf '\n\033[1m────────────────────────────────\033[0m\n'
printf '\033[32m%d passed\033[0m' "$PASS"
[ $FAIL -gt 0 ] && printf ', \033[31m%d failed\033[0m' "$FAIL"
[ $SKIP -gt 0 ] && printf ', \033[33m%d skipped\033[0m' "$SKIP"
printf '\n'
[ $LONG -eq 0 ] && printf 'Run with --long to also cover the 403 fallback (~1GB).\n'
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
