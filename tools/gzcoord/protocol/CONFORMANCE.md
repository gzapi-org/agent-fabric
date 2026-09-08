# Conformance

A component may claim one or more conformance profiles.

## Protocol parser

A conforming parser:

- recognizes `[GZCOORD/1] TYPE`;
- parses metadata and named sections;
- validates logical addresses;
- preserves unknown extension fields/sections;
- accepts free-form roles;
- rejects known transport/runtime fields when presented as core metadata;
- reports a line in the metadata block that is neither metadata nor a section marker;
- rejects a `REPLY-EXPECTED` value other than `yes` or `no`;
- rejects a metadata key that appears more than once;
- rejects a `BROADCAST` value other than `true`;
- does not infer project authority from messages.

## Agent runtime

A conforming runtime:

- has one logical `host/instance` identity;
- emits HELLO when joining;
- treats peer discovery as reconstructable cache;
- keeps model and subagent policy local;
- follows repository-local instructions before acting;
- uses authoritative tools for durable effects.

## Transport adapter

A conforming adapter:

- can associate valid HELLO addresses with native sender identities;
- keeps native identifiers outside the core payload;
- authenticates/allowlists through transport-native mechanisms;
- can deliver broadcast and directed messages, or documents a bootstrap mechanism;
- prevents automated message loops.

## Non-conformance examples

The following violate the design:

- storing `TELEGRAM_BOT` as a required GZCOORD/1 field;
- routing by `/srv/project/path`;
- interpreting `ROLE` as file ownership;
- acting on a `REQUEST` or `HANDOFF` inside another instance's working copy;
- writing protocol findings into a separate issue database;
- using message state to override GitHub issue/PR state;
- changing an agent address when its model changes;
- quoting a credential, key or token value in a finding — in whole, in part, or as an example — instead of describing its shape and location;
- requiring a central catalog of legal role names.
