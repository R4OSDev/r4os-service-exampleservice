# EXSVC.R4X

`EXSVC.R4X` is an independent R4OS service implemented in Zig.

## Package

- Version: `0.1.4`
- Image target: `/R4OS/SERVICES/EXSVC.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Service-loop example

The regular `/RUN` mode uses `r4os.ServiceLoop` as the canonical service
pattern: endpoint waits are event-driven, stop handling uses the shared
safety budget, and ready requests are drained in bounded batches without a
forced tick per request.

The explicit `/BENCHMARK` launch mode runs five 8-by-8 concurrent request
samples after a two-second idle window. It records every queue-age and
end-to-end observation plus sample and overall distributions in
`C:\TEMP\SVCBENCH.TXT`. The headless Terminal harness uses
`/SELFTEST /BENCHMARK /KEEP` so the service-class artifact runs under the
Terminal's explicit selftest launch policy. `/SELFTEST` and `/PING` remain the
functional modes.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
