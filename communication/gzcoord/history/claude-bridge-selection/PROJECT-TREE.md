# Layout

> Historical (2026-09-16): the tree under the human relay; see
> `README.md` beside this file. `communication/gzcoord/README.md` is the
> current map.

GZCoord lives in agent-fabric, the control plane every managed repository
shares. The core — protocol, runtime, tests, transport-neutral docs — is
here; what one project does with it is under that project.

```text
agent-fabric/
├── communication/
│   └── gzcoord/
│       ├── README.md
│       ├── package.json
│       ├── protocol/
│       │   ├── SPEC.md
│       │   ├── MESSAGE-FORMAT.md
│       │   ├── SEMANTICS.md
│       │   ├── CONFORMANCE.md
│       │   └── examples/
│       │       ├── hello.txt
│       │       ├── observation.txt
│       │       ├── observation-diagnosis.txt
│       │       ├── reply.txt
│       │       └── review.txt
│       ├── runtime/
│       │   └── README.md               identity and role sourcing
│       ├── config/
│       │   └── instance.example.yaml
│       ├── scripts/
│       │   ├── gzmsg.mjs               parser, validator, hello, new-id
│       │   └── inbox.mjs               relay client: drain, --wait, --keyword
│       ├── tests/
│       │   └── protocol.test.mjs
│       ├── docs/
│       │   ├── PROJECT-TREE.md
│       │   ├── TRANSPORT-ADAPTER-CONTRACT.md
│       │   ├── TRANSPORT-CANDIDATE-CLAUDE-BRIDGE.md
│       │   ├── HUMAN-RELAY-TRANSPORT.md
│       │   └── CLAUDE-CODE-HOST-INTEGRATION-PROMPT.md
│       └── history/
│           └── telegram-transport/     # retired, not instruction
│               ├── README.md
│               ├── TELEGRAM-ADAPTER.md
│               └── TELEGRAM-SETUP.md
├── identities/roles/catalog.json       the role slugs ROLE / TO-ROLE are held to
├── runtime/identity.py                 the agent: <host>/<login>
└── projects/
    └── gzapp/integration/gzcoord/      one project's use of the protocol
        ├── INSTALL.md
        ├── CLAUDE.md                   the subsystem context gzapp sessions read
        ├── CLAUDE.snippet.md           what gzapp's root CLAUDE.md carries
        └── BRIDGE-RELAY-SETUP.md       the relay gzapp hosts, and its hooks
```

There is no `adapters/` directory: the reference transport is a human
relay (`docs/HUMAN-RELAY-TRANSPORT.md`) and needs no adapter code; gzapp
runs a Claude-Bridge relay described in its own integration. The
interface an automated adapter must satisfy is
`docs/TRANSPORT-ADAPTER-CONTRACT.md`; candidates evaluated against it get
one `TRANSPORT-CANDIDATE-*.md` each, and evaluating one is not selecting
it.

Local, not committed:

```text
~/.config/gzcoord/<project>.yaml        instance configuration
$AGENT_FABRIC_STATE_DIR/agents/<login>/ the agent's role binding (read, never written, by GZCoord)
```

Adapter credentials and state live outside the repository too, in whatever
location the chosen transport needs — the human relay needs none.
