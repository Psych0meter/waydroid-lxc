"""
Shared building blocks every action module uses: a uniform result/error
type, and a subprocess runner for driving the shell tools in
4-waydroid-tools/ safely.
"""
from __future__ import annotations

import subprocess
from dataclasses import dataclass, field
from typing import Any, Sequence


class ActionError(Exception):
    """
    Raised by an action for any expected failure: bad input, the wrapped
    script exiting non-zero, a timeout, a missing binary. Routes catch
    this specifically and turn it into a 400 JSON response - anything
    else propagates as a real 500, since it means something we didn't
    anticipate.
    """


@dataclass
class ActionResult:
    ok: bool
    message: str
    data: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {"ok": self.ok, "message": self.message, "data": self.data}


def validate_number(value: object, name: str, lo: float, hi: float) -> float:
    """
    Parses `value` as a float and checks it falls within [lo, hi],
    raising ActionError with a message safe to return straight to a
    client on any failure. Shared by any action that takes numeric
    input (actions/gps.py's coordinates, actions/favorites.py's saved
    coordinates) so the same validation rules apply everywhere a
    latitude/longitude/altitude is accepted.
    """
    if isinstance(value, bool) or value is None:
        raise ActionError(f"{name} is required and must be a number.")
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        raise ActionError(f"{name} must be a number, got: {value!r}") from None
    if not (lo <= parsed <= hi):
        raise ActionError(f"{name} must be between {lo} and {hi}, got: {parsed}")
    return parsed


def run_script(args: Sequence[str], timeout: int = 30) -> subprocess.CompletedProcess:
    """
    Runs a 4-waydroid-tools/ script as a subprocess.

    Always called with `args` as a list, NEVER shell=True and NEVER a
    pre-joined string - this is what keeps user-supplied values (typed
    into the web form, or posted to the API) from ever being interpreted
    as shell syntax, no matter what characters they contain. Validate
    values BEFORE calling this (see e.g. actions/gps.py); this function
    only worries about actually running the command.
    """
    try:
        return subprocess.run(
            list(args),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        raise ActionError(f"Script not found: {args[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise ActionError(
            f"Timed out after {timeout}s running: {' '.join(args)}"
        ) from exc
