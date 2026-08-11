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
- moves an agent out of the working copy it started in;
- grants access to another agent's checkout, branch or pull request;
- blocks a merge;
- approves a pull request;
- records an ADR;
- changes repository permissions;
- resolves a conflict;
- establishes durable organizational truth.

If such an effect is required, use the authoritative tool explicitly.

## Role is not authentication

`ROLE: Application Architect` is a self-description. The transport adapter authenticates a native sender identity according to local channel policy. Organizational trust in that identity is a deployment concern, not a wire-format claim.

## Role is not identity

A role is a classification shared by however many instances currently hold it; the instance is the peer. Only `host/instance` identifies a peer. `TO-ROLE` addressing is therefore one-to-many, and a reply to "the Backend Engineer" is a reply to whichever instance answered, not to the role.

## Git context is descriptive

`BRANCH` and `COMMIT` help peers reproduce the sender's context. They never imply exclusive ownership.
