#!/bin/sh
# llama-server tuned to drive opencode locally on a 16 GB Apple Silicon Mac.
#
#   brew install llama.cpp
#   ~/.config/llamacpp/llama-server.sh          # foreground, for debugging
#   launchctl kickstart -k gui/$(id -u)/com.maruan.llama-server
#
# This replaces the Ollama runtime. Ollama also shells out to llama-server, but
# it launches it with `--no-jinja --chat-template chatml`, which discards the
# model's own chat template. That is not a tuning detail: the template is what
# defines the <tool_call> wrapper, so without it llama.cpp has nothing to parse
# tool calls out of and they come back as prose in the message body. That is the
# whole reason Qwen2.5-Coder "did not support tools" here - it was never the
# model. Running llama-server directly with the model's real template fixes it.
#
# Verify what Ollama is doing to a model with:
#   ps aux | grep llama-server
#
# --------------------------------------------------------------- the model ----
#
# Qwen3.5-9B at UD-Q4_K_XL: 5.97 GB of weights, leaving room for a real context
# window inside 16 GB shared between the GPU and the rest of the machine.
# Download with:
#
#   curl -L -o ~/models/gguf/Qwen3.5-9B-UD-Q4_K_XL.gguf \
#     https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-UD-Q4_K_XL.gguf
#
# The 30B-class models that are genuinely strong at agentic coding
# (Qwen3-Coder-30B-A3B, Devstral-24B) need ~18 GB at Q4. Q3 fits on paper at
# ~13 GB but leaves nothing for KV cache or macOS, and swaps. 9B dense is the
# ceiling on this machine.

set -eu

MODEL="${LLAMA_MODEL:-$HOME/models/gguf/Qwen3.5-9B-UD-Q4_K_XL.gguf}"
PORT="${LLAMA_PORT:-8080}"

[ -f "$MODEL" ] || {
    echo "model not found: $MODEL" >&2
    echo "see the download command in the header of this script" >&2
    exit 1
}

exec llama-server \
    --model "$MODEL" \
    --alias qwen3.5-9b \
    --host 127.0.0.1 \
    --port "$PORT" \
    --ctx-size 32768 \
    --n-gpu-layers 99 \
    --flash-attn on \
    --cache-type-k q8_0 \
    --cache-type-v q8_0 \
    --jinja \
    --reasoning off \
    --temp 0.7 \
    --top-p 0.8 \
    --top-k 20 \
    --min-p 0.0 \
    --repeat-penalty 1.05 \
    --parallel 1 \
    --cache-reuse 256 \
    --no-context-shift \
    --no-webui \
    "$@"

# --------------------------------------------------------------- the flags ----
#
# --jinja           Uses the chat template shipped inside the GGUF instead of a
#                   generic one. Required for tool calling: llama.cpp picks a
#                   model-specific tool-call parser off the back of it and
#                   returns a structured `tool_calls` field, which is what
#                   opencode reads. Without it, requests carrying a `tools` array
#                   are rejected outright with "tools param requires --jinja".
#                   Default is already `on` in recent builds; set explicitly
#                   because everything here depends on it.
#
# --reasoning off   Qwen3.5 is a hybrid model and thinks by default. On an M1 Pro
#                   that is minutes of thinking tokens before every tool call.
#                   This is the supported way to force it off - it drives the
#                   template's own enable_thinking switch. The old Ollama setup
#                   had to inline a hand-edited copy of the template to achieve
#                   the same thing, because `think: false` is ignored on the
#                   OpenAI-compatible /v1 endpoint that opencode talks to.
#
# --ctx-size 32768  opencode's system prompt plus tool definitions is ~5.4k
#                   tokens, so a small context truncates the conversation
#                   silently and the agent behaves erratically. The model itself
#                   supports 262k; 32k is what the memory budget allows here.
#                   ~2.4 GB of KV cache at q8_0, ~8.5 GB resident all in.
#
# -ctk/-ctv q8_0    Halves KV cache against f16 for no measurable speed cost and
#                   no quality difference that shows up in this workload.
#
# --cache-reuse 256 Agent prompts change in the middle, not at the end - a file
#                   listing or timestamp shifts and everything after it moves.
#                   This lets the server KV-shift around a changed chunk instead
#                   of reprocessing the whole prefix, which is most of what
#                   makes follow-up turns fast.
#
# --no-context-shift  When the context fills, fail loudly rather than silently
#                   evicting the system prompt and tool definitions. A truncated
#                   tool schema produces malformed calls that look like model
#                   failures and are painful to diagnose.
#
# --parallel 1      One slot, so the whole KV cache backs a single conversation.
#                   opencode is one conversation at a time; more slots would just
#                   split the context window.
#
# temp 0.7 / top_p 0.8 / top_k 20
#                   Qwen's published non-thinking sampling settings. Drop the
#                   temperature toward 0.3 if tool arguments come back malformed;
#                   going much below that makes the model loop instead.
