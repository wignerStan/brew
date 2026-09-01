# typed: strict
# frozen_string_literal: true

# Stable public entry point for the native user-overlay subsystem.
#
# Keep callers on `require "overlay"`; implementation files live below
# `overlay/` so they can be reorganized without widening Homebrew's rebase
# surface.
require "overlay/core"
