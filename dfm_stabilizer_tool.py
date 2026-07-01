#!/usr/bin/env python3
"""Entry point for the Python port of DFMStabilizerTool. See dfm_stabilizer_cli for usage."""

import sys

from dfm_stabilizer_cli import run

if __name__ == "__main__":
    sys.exit(run())
