"""
Action registry for the Waydroid webapp.

An "action" is a small, self-contained module of one Android/Waydroid
interaction - GPS mock-location, saved favorites, screen control
(screenshot/tap/swipe/text/key), address geocoding, self-update today;
app launch/install, notifications, etc. could each be their own action
module later. Keeping every action in its own file under actions/,
wrapped by its own thin Flask blueprint under routes/, is what makes
adding a new capability a matter of adding two small files rather than
touching shared code - see "Adding a new action" in README.md.

Every action module exposes plain functions that take validated
arguments and return an ActionResult (actions/base.py) or raise an
ActionError - no Flask/HTTP concerns belong in here, only in routes/, so
actions stay usable from a CLI, a test, or a future non-HTTP entry point
without dragging Flask along.
"""
