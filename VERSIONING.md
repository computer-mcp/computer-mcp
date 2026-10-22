# Versioning

This repository adopts the organization's
[Versioning rules](https://github.com/computer-mcp/.github/blob/master/VERSIONING.md).
The following additions apply to the host. Version sources, mirrors, release
procedure and checks are in the
[Release Reference](Documentation/Reference/Release.md).

## App candidates

Build numbers increase when an App candidate is revised. An unsuccessful
candidate does not consume a new formal patch version.

## Version review records

Every version update records the component, change kind and rationale in the
change review and changelog.

## Bundled plugins

Before the first host release, a bundled plugin archive may be adopted from an
accepted plugin commit before that plugin version is published. A host release
requires each bundled plugin's release with the same archive digest to be
public first.
