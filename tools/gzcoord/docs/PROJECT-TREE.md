# Recommended GZAPP tree

```text
gzapp/
├── .git/
├── CLAUDE.md
├── ADR/
├── contracts/
├── src/
├── ...
└── tools/
    └── gzcoord/
        ├── README.md
        ├── protocol/
        │   ├── SPEC.md
        │   ├── MESSAGE-FORMAT.md
        │   ├── SEMANTICS.md
        │   ├── CONFORMANCE.md
        │   └── examples/
        │       ├── hello.txt
        │       ├── observation.txt
        │       ├── observation-diagnosis.txt
        │       ├── reply.txt
        │       └── review.txt
        ├── runtime/
        │   └── README.md
        ├── config/
        │   └── instance.example.yaml
        ├── integration/
        │   └── CLAUDE.snippet.md
        ├── scripts/
        │   └── gzmsg.mjs
        ├── tests/
        │   └── protocol.test.mjs
        ├── docs/
        │   ├── INSTALL-IN-GZAPP.md
        │   ├── PROJECT-TREE.md
        │   ├── TRANSPORT-ADAPTER-CONTRACT.md
        │   ├── BRIDGE-RELAY-SETUP.md
        │   ├── HUMAN-RELAY-TRANSPORT.md
        │   └── CLAUDE-CODE-HOST-INTEGRATION-PROMPT.md
        ├── history/
        │   └── telegram-transport/     # retired, not instruction
        │       ├── README.md
        │       ├── TELEGRAM-ADAPTER.md
        │       └── TELEGRAM-SETUP.md
        ├── CLAUDE.md
        └── package.json
```

There is no `adapters/` directory: the current transport is a human relay
(`docs/HUMAN-RELAY-TRANSPORT.md`) and needs no adapter code. The interface an
automated adapter must satisfy is `docs/TRANSPORT-ADAPTER-CONTRACT.md`.

Local, not committed:

```text
~/.config/gzcoord/
└── gzapp.yaml
```

Adapter credentials and state live outside the repository too, in whatever
location the chosen transport needs — the human relay needs none.
