# `moveto`

Open a shell as another role account, in that account's working clone, with the
window title set to the session.

```
moveto architect-cto-01        # shell as that account, in its clone
moveto user legacy-clone-2     # name the clone when an account holds several
moveto --list                  # accounts that have at least one clone
moveto <account> --list        # that account's clones
moveto <account> --print       # resolve only — print path and title, spawn nothing
```

`exit` returns to the shell you came from.

This is **host tooling, not part of the product.** It is installed to
`/usr/local` and is not delivered by a `git clone`; this directory is the
source, and `install.sh` is how it gets there.

## Install

```sh
sudo tools/moveto/install.sh
```

Three files land: `/usr/local/bin/moveto`, `/usr/local/share/moveto/enter`, and
`/usr/local/share/moveto/rc`. The copy under `/usr/local` can drift from this
directory and nothing detects it — re-run the installer after any change here.

## What it assumes

**The layout is `~/projects/<account>`.** Resolution order: a clone named
explicitly on the command line, else `~/projects/<account>`, else the only
entry in `~/projects` if there is exactly one, else it lists them and stops. An
account whose `~/projects` is empty is reported as not provisioned rather than
dropping you in `$HOME`, because landing somewhere unexpected is worse than
being told.

**It goes one way.** `sudo` on this host is granted through the `qubes` group,
and the role accounts are not in it — so an account that has sudo can become a
role account, and a role account can become nothing. `exit` is the way back,
which is why nothing here tries to be a two-way switch.

## What it gives you, and what it does not

`sudo` runs its PAM session stack — `/etc/pam.d/sudo` includes `system-auth`,
which carries `pam_systemd` — so a `moveto` shell gets its own
`/run/user/<uid>`, which is what rootless podman needs. Verified by watching
the directory appear for an account that had none. (`-H` only sets `HOME`; it
is not what creates the session.) What it does **not** give
you is persistence: that directory is removed when the account's last session
ends, so anything expected to outlive the shell needs
`sudo loginctl enable-linger <account>`, which
[`.roles/PROVISIONING.md`](../../.roles/PROVISIONING.md) does when standing an
account up.

That document is the other half of this one: it covers creating a role account
and moving a session into it; this covers getting into one afterwards.

## The title

The title is the **role instance** — the account name — because that is what
names a session. The one exception is an account holding several clones, where
its own name cannot tell two sessions apart and the clone name is used instead;
once every session has its own account, that branch never fires.

Qubes prefixes window titles with the VM name, so the result reads like
`[develop-qzapp] architect-cto-01`. That prefix is the GUI daemon's, not ours.

## Three things that are easy to get wrong here

Each of these was a live defect during development, and each is invisible when
you get it wrong — which is why they are written down rather than left to the
code.

**`bash -c '…"$1"…' _ "$dir"` under `sudo -i` loses the path.** Two things
combine: `-c` consumes its first following argument as `$0`, and `sudo -i`
concatenates the command and its arguments into one string for the login shell
(`man sudo`), escaping everything except alphanumerics, underscores, hyphens
and — note — `$`. The original form hit both, and `cd` failed with `null
directory`. `enter` is a plain command with real arguments now, which is the
shape that works; the `$`-not-escaped part is the footgun worth remembering if
anything ever goes back through `-i`. Login processing (`PATH` from
`/etc/profile` and `~/.bash_profile`) comes from `-l` in `enter`'s own shebang.

**The entering shell is a file, not an inline `bash -lc '...'`.** The inline
form put the whole script — 156 characters of it — on the process command line,
and a terminal that titles from the running command showed *that* instead of
the session name.

**`PROMPT_COMMAND` already has a title write in it.** `/etc/bashrc` rewrites
the title as `user@host:cwd` at every prompt, so a one-shot title is
overwritten within a second — `enter` sets the title before the first prompt
*and* `rc` re-sets it at each one.

On Fedora that variable is an **array**: `/etc/bashrc` does `declare -a
PROMPT_COMMAND` and sets element 0, then vte.sh and the systemd OSC-context
hook append further elements. A string append therefore reads and writes
element 0 only — it neither disturbs those hooks (a plain clobber would not
have either) nor runs after them. Ours lands inside element 0 and runs *before*
elements 1..n, which is harmless only because vte.sh deliberately leaves the
title alone in the array case. A `~/.bashrc` appending its own title hook as a
later element would win.

OSC 1 (tab) and OSC 2 (window) are set explicitly rather than OSC 0, which
means "both" and is honoured inconsistently.

## Tests

```sh
bash tools/moveto/test_moveto.sh
```

Covers the resolution matrix through `--print`, which runs the whole resolution
path and stops before the exec. `getent` and `sudo` are mocked on `PATH`, so the
suite needs neither root nor the real accounts.

The fixture set includes an account whose single clone is named *differently*
from the account. That one exists because without it a mutant that always titles
by clone basename passes every other assertion — under the template layout the
account name and the clone name are the same string, so nothing can tell the two
rules apart. Both that mutation and "silently pick the first clone" were checked
to fail the suite.
