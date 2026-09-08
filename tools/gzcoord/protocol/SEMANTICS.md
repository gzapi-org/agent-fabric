# Semantics and Non-Semantics

This document exists to prevent GZCoord from slowly becoming a second project-management system.

## What a message means

`OBSERVATION`
: "I noticed this and think it may matter."

`QUESTION`
: "I need information or clarification."

`REQUEST`
: "I am asking you to do something."

`REVIEW`
: "Please examine this before the authoritative workflow proceeds."

`DECISION`
: "I am communicating a decision from my role/context. Record it where project policy requires."

`HANDOFF`
: "I am transferring context/responsibility by agreement."

## What a message does not mean

None of these messages automatically:

- creates a GitHub issue;
- changes an issue state;
- owns a branch;
- reserves a file;
- reserves a finding, task or fix for the sender;
- moves an agent out of the working copy it started in;
- grants access to another agent's checkout, branch or pull request;
- blocks a merge;
- approves a pull request;
- records an ADR;
- changes repository permissions;
- resolves a conflict;
- establishes durable organizational truth.

If such an effect is required, use the authoritative tool explicitly.

## When a reply is expected

Every message a transport carries has a cost — over a human relay, a person's. A thread therefore ends in silence, not in a closing message, and **an acknowledgement is terminal**: nobody acknowledges an acknowledgement. Completion is announced by the pull request, not by another message.

By default:

- `QUESTION`, `REQUEST`, `REVIEW`, `HANDOFF` — a reply is expected: an answer, an acknowledgement by reference, a decline, an acceptance.
- `OBSERVATION` — a reply is expected only if the recipient acts on it, and then only to say where (MESSAGE-FORMAT.md, "Acknowledging by reference"). Its purpose is to prevent duplicate work, not to say thanks.
- `HELLO`, `GOODBYE`, `INFO`, `DECISION`, `REPLY` — no reply is expected.

`REPLY-EXPECTED: yes | no` (SPEC.md §7.4) overrides the default for one message. Neither the default nor the override obliges anyone: "expected" describes what the sender is waiting for, and "no" tells the carrier not to come back for one.

## Role is not authentication

`ROLE: Application Architect` is a self-description. The transport adapter authenticates a native sender identity according to local channel policy. Organizational trust in that identity is a deployment concern, not a wire-format claim.

## Role is not identity

A role is a classification shared by however many instances currently hold it; the instance is the peer. Only `host/instance` identifies a peer. `TO-ROLE` addressing is therefore one-to-many, and a reply to "the Backend Engineer" is a reply to whichever instance answered, not to the role.

## Git context is descriptive

`BRANCH` and `COMMIT` help peers reproduce the sender's context. They never imply exclusive ownership.

A `REPLY` whose `REFERENCES` name a branch or pull request says where its
sender is working. That is a report, not a reservation: it does not stop
another instance from working on the same thing, and it does not commit
the sender to finishing. A peer that reads it decides for itself.
