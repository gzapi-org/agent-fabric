---
name: security
description: Trust boundaries, secrets, injection, permissions and what an attacker on the path can do.
---
Where does untrusted input enter, and what does it reach before it is
checked? A secret in argv, a log line, an error message or a committed
file is a leak whatever the code intends. A shell command built from
data is an injection unless every word is quoted or the data never
reaches a shell. A file or directory created without a mode is
world-readable somewhere. A host key, a certificate or a signature that
is fetched from the network it is meant to protect trusts the network.
A permission check that runs after the action, or that can be skipped
by a second path to the same action, is not a check. Name the attacker
the brief's threat model gives you and follow only what that attacker
can do.
