"""
Address -> coordinates lookup, via OpenStreetMap's Nominatim search API.

No API key needed (unlike Google's geocoder, which would require billing
setup), which fits this repo's existing preference for unkeyed, no-signup
tools. Nominatim's public instance has a strict usage policy though: at
most ~1 request/second, a descriptive User-Agent identifying the calling
application, and no heavy/automated use - fine for a human clicking
"search" in this webapp occasionally, not for bulk geocoding. See
https://operations.osmfoundation.org/policies/nominatim/. Proxying the
request through this backend (rather than calling Nominatim directly from
the browser) keeps that User-Agent and any future API-key swap
server-side, and is what protects nominatim.openstreetmap.org from a
misbehaving client hammering it directly.
"""
from __future__ import annotations

import requests

from .base import ActionError, ActionResult

NOMINATIM_SEARCH_URL = "https://nominatim.openstreetmap.org/search"
USER_AGENT = "waydroid-lxc-webapp/1.0 (+https://github.com/Psych0meter/waydroid-lxc)"
_REQUEST_TIMEOUT = 10
_MAX_ADDRESS_LENGTH = 500


def geocode_address(address: object, limit: int = 5) -> ActionResult:
    if not isinstance(address, str):
        raise ActionError("address must be a string.")
    address = address.strip()
    if not address:
        raise ActionError("address must not be empty.")
    if len(address) > _MAX_ADDRESS_LENGTH:
        raise ActionError(f"address must be at most {_MAX_ADDRESS_LENGTH} characters.")

    try:
        response = requests.get(
            NOMINATIM_SEARCH_URL,
            params={"q": address, "format": "jsonv2", "limit": max(1, min(limit, 10))},
            headers={"User-Agent": USER_AGENT},
            timeout=_REQUEST_TIMEOUT,
        )
        response.raise_for_status()
        payload = response.json()
    except requests.RequestException as exc:
        raise ActionError(f"Geocoding request failed: {exc}") from exc
    except ValueError as exc:
        raise ActionError("Geocoding service returned an unexpected response.") from exc

    results = []
    for item in payload if isinstance(payload, list) else []:
        try:
            results.append(
                {
                    "display_name": item["display_name"],
                    "latitude": float(item["lat"]),
                    "longitude": float(item["lon"]),
                }
            )
        except (KeyError, TypeError, ValueError):
            continue  # skip a malformed entry rather than failing the whole search

    if not results:
        raise ActionError(f"No results found for: {address}")

    return ActionResult(
        ok=True,
        message=f"Found {len(results)} result(s).",
        data={"results": results},
    )
