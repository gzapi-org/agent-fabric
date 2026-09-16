---
name: portability
description: Shell dialects, login-shell profiles, package names, paths and privileges across platforms.
---
A `#!/bin/sh` runs under dash on Debian; a bashism there is a syntax
error on the second platform. A login shell (`bash -l`) sources
`/etc/profile`, which on Debian assigns PATH outright — whatever the
caller set is gone. A tool assumed present (`cmp`, `hostname`, `gh`) is
a package on one platform and absent on a minimal image of another. A
package name differs per distribution (`git-core`/`git`, `gnupg2`/
`gnupg`). A test that runs as root behaves differently from the
unprivileged login a host actually runs. `/usr/local` persists on a
Qubes AppVM; a package does not. Name the platforms the brief says are
supported and trace the change on each.
