# Install inside GZAPP

Copy the `tools/gzcoord/` directory into the root of the GZAPP repository.

Do not create a nested Git repository.

Add the contents of `integration/CLAUDE.snippet.md` to the project's root `CLAUDE.md` (or reference it from the project rules if that repository already has a modular rules structure).

Create the concrete instance configuration outside Git, for example:

```text
~/.config/gzcoord/gzapp.yaml
```

Use `config/instance.example.yaml` only as a template. Fill `role.name`
and `specialties` from the role this working copy currently holds
under `.roles/` (`tools/roles/switch.py --status`) — do not author a
role name independently of `.roles/taxonomy.json`; see
`../runtime/README.md` "Role sourcing".

Transport credentials and adapter state must also stay outside the project
repository.

The current transport is the human relay ([`HUMAN-RELAY-TRANSPORT.md`](HUMAN-RELAY-TRANSPORT.md)):
no credentials, no state directory, and nothing to configure at step 4
beyond `adapter: human-relay` — see [`../CLAUDE.md`](../CLAUDE.md).
