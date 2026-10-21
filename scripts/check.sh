#!/bin/zsh
# The checks that need no microphone: the talk key's timing, and the text rules (spoken
# breaks, the AI guard, styles, spoken symbols, "press enter", forms, learning).
set -euo pipefail
cd "${0:A:h}/.."
cat Mac/FnKey.swift Mac/FnKeyCheck.swift | swift -
cat Mac/Rules.swift Mac/RulesCheck.swift | swift -
