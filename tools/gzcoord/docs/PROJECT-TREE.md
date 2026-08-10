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
        ├── adapters/
        │   └── telegram/
        │       └── README.md
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
        └── package.json
```

Local, not committed:

```text
~/.config/gzcoord/
└── gzapp.yaml

~/.claude/channels/telegram/
└── <instance>/
    ├── .env
    └── ...
```
