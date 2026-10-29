"""nanda-harness: the external LLM agent harness for NANDA Town in Roblox.

The Roblox server polls this service over HttpService and feeds the actions it
returns into the game's existing policy interface
(roblox/src/shared/NandaTown/RedBlue/Policy.luau). Standard library only, so
there is nothing to install: `harness/run.sh`.
"""

__version__ = "1.0.0"
