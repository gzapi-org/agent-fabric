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
        │   └── CLAUDE-CODE-HOST-INTEGRATION-PROMPT.md
        ├── history/
        │   └── telegram-transport/     # retired, not instruction
        │       ├── README.md
        │       ├── TELEGRAM-ADAPTER.md
        │       └── TELEGRAM-SETUP.md
        ├── CLAUDE.md
        └── package.json
```

There is no `adapters/` directory: no transport is selected. The interface a
future adapter must satisfy is `docs/TRANSPORT-ADAPTER-CONTRACT.md`.

Local, not committed:

```text
~/.config/gzcoord/
└── gzapp.yaml
```

Adapter credentials and state live outside the repository too, in whatever
location the chosen transport needs — there is none at present.
