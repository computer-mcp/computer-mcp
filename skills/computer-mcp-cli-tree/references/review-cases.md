# Authoring review cases

Use task-owned temporary output and actual source evidence. These are review
prompts, not benchmark scores or precomputed success claims.

1. A vendor's version remains unchanged but its official machine help changes
   an option from a repeated string to an integer. Update a partial plugin tree
   and describe the compatibility evidence. Check mappings against the new
   type; do not merely replace the hash.
2. An existing tree documents a false default and a one-way enable flag. Verify
   the vendor's omission/false behavior and correct any schema or mapping issue
   without inventing an inverse flag or automatically emitting the default.
3. A tree contains a secret default, an unsupported schema keyword, and a
   missing parent node. Use the host validator to locate and correct each issue;
   never reproduce the secret in evidence or user-facing diagnostics.
4. A user only wants to run an existing CLI command against their project.
   Use the ordinary CLI workflow; do not create or install a tree or change
   permissions merely because this skill exists.
5. A new version check passes but a command's JSON output shape is undocumented.
   Keep that output and coverage honest; a successful version probe is not
   evidence for an invented JSON schema or complete command coverage.
