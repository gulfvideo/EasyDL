# Security

## Reporting

Open a [security advisory](https://github.com/gulfvideo/EasyDL/security/advisories/new)
or a regular issue if it isn't sensitive. This is a small hobby project — expect a
best-effort response, not an SLA.

## What EasyDL is, in security terms

It builds a `yt-dlp` command line and runs it as a subprocess. It does not parse media,
does not listen on a socket, and makes no network requests of its own. The untrusted
input it handles is: URLs you paste, and whatever `yt-dlp` prints back — which includes
strings chosen by a remote server, such as video and playlist titles.

Arguments are passed as an `argv` array, never through a shell, so there is no shell
injection surface. URLs must start with `http://` or `https://` before EasyDL will
accept them, and they are passed after a `--` separator so they can never be parsed as
options.

## Deliberate decisions

- **Not sandboxed.** It spawns `yt-dlp` and writes wherever you point it. Sandboxing
  would break both.
- **Not notarized.** Builds are ad-hoc signed, which is enough to run on the machine
  that built them. Notarization needs a paid Apple Developer account.
- **`--ignore-config` on every run**, so a `~/.config/yt-dlp/config` you forgot about
  cannot change what the GUI does.
- **Double-click only opens media.** The file extension comes from the server, not from
  the format you picked, and files written by `yt-dlp` carry no quarantine flag — so a
  hostile URL could otherwise yield `clip.command` that runs on a double-click. Anything
  outside the media allowlist is revealed in the Finder instead.
- **Playlist folder names are guarded.** The folder is remote-controlled and is a real
  path component; `yt-dlp` replaces `/` in a field value but leaves a lone `..` alone,
  and its `sanitize_path()` does not drop `..` on macOS. The template appends a
  bracketed id so the folder can never be exactly `.` or `..`.
- **`PYTHONPATH`, `PYTHONHOME`, `PYTHONSTARTUP` and `PYTHONWARNINGS` are stripped** from
  the child environment, because `yt-dlp` is a Python program and those would let
  inherited environment variables decide what it imports.
- **Remote strings are JSON-encoded in yt-dlp's output.** EasyDL reads progress and
  completion back out of yt-dlp's stdout using marker lines. Video titles are chosen by
  the server, and with a plain `%(title)s` a newline inside a title splits the output
  into two lines — so a video called `Innocent\n@@DONE@@/somewhere/else.mp4` could forge
  a completion line and take over the path EasyDL later reveals or opens. The `j`
  conversion escapes it, the markers are only recognised at the start of a line, and a
  completed path is ignored unless it resolves inside your download folder.
- **The saved queue is `0600`.** It records every URL you have downloaded.

## Things you are trusting

- **`yt-dlp` and `ffmpeg`**, installed by you via Homebrew. EasyDL runs whichever copy
  it finds. It does not bundle or auto-update them.
- **`yt-dlp` plugins.** Any Python in `~/.config/yt-dlp/plugins/` runs on every
  invocation. That is how the optional PO token provider works, and it is why that
  installer pins an upstream commit id and verifies the plugin archive's SHA-256 before
  unpacking it.
- **npm.** `install-pot-provider.sh` runs `npm ci`, which executes install scripts from
  the whole dependency tree. That is inherent to npm and is the main reason the provider
  is optional.
- **Your cookie file**, if you use one. It is a set of live session tokens. Keep it
  `chmod 600`, trim it to the sites you need, and never commit or share it. EasyDL only
  passes its path to `yt-dlp`; it never reads or transmits the contents.

## Not claimed

No formal audit, no fuzzing, no threat model beyond the above. If you find something,
please report it.
