# Sandboxed gemini-cli image for the FR-16 opt-in containerized gemini lane (GEMINI_SANDBOX=docker).
#
# Project: unimatrix — multi-model swarm orchestrator driven from Claude Code
# Module:  docker/gemini-lane.Dockerfile
# Deps:    node:22-slim (npm), @google/gemini-cli
# Tested:  tests/swarm-lib.bats (argv shape, fake docker), tests/swarm-run.bats (full round trip,
#          fake docker+gemini), docs/ops/llm-runs.md (one live sandboxed PONG receipt)
#
# Key responsibilities:
# - Bake gemini-cli at the SAME version pinned in docs/versions.md for the host lane (0.49.0) —
#   no drift between the sandboxed and unsandboxed gemini behavior.
# - Nothing else: no repo checkout, no credentials baked in. The API key and trust flag are
#   injected per spawn via `docker run -e ...` (src/swarm-lib.sh lane_cmd) — never COPYed here.
#
# Design constraints:
# - ghcr.io/google/gemini-cli:latest was tried first (it's gemini's own --sandbox default image)
#   and is NOT publicly pullable (`denied` on anonymous pull) — hence this minimal custom image.
# - No ENTRYPOINT/CMD baked in: lane_cmd's argv always names `gemini ...` explicitly after the
#   image ref, so the image just needs the binary on PATH.
FROM node:22-slim
RUN npm install -g @google/gemini-cli@0.49.0
