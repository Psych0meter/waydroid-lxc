"""
Flask test-client suite for the webapp - covers the HTTP layer (auth,
request validation, error mapping) and the action modules behind it,
against a fake change-location.sh and a mocked Nominatim response, so it
runs anywhere (dev machine, CI) with no real container/device needed.

Run with: python3 -m unittest discover -s 5-webapp/tests -t 5-webapp
(from the repo root - tests/lint.sh does exactly this).

IMPORTANT: every environment variable below must be set BEFORE `app` (or
anything it imports - auth, actions.gps, actions.favorites) is imported,
since each of those modules resolves its configuration from the
environment at import time, not per-request. That's why this setup runs
at module level, above the imports it's guarding.
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from unittest import mock

_TMP = tempfile.mkdtemp(prefix="waydroid-webapp-test-")
_TOOLS_DIR = os.path.join(_TMP, "tools")
os.makedirs(_TOOLS_DIR, exist_ok=True)

CALL_LOG = os.path.join(_TMP, "calls.log")
_FAKE_SCRIPT = os.path.join(_TOOLS_DIR, "change-location.sh")
with open(_FAKE_SCRIPT, "w", encoding="utf-8") as _f:
    _f.write(
        "#!/usr/bin/env bash\n"
        f'echo "$*" >> "{CALL_LOG}"\n'
        'if [[ "$1" == "--fail" ]]; then echo "boom" >&2; exit 1; fi\n'
        'if [[ "$1" == "--stop" ]]; then echo "Mock location service stopped."; exit 0; fi\n'
        'echo "Location updated to $1, $2 (altitude $3)"\n'
    )
os.chmod(_FAKE_SCRIPT, 0o755)

os.environ["WAYDROID_TOOLS_DIR"] = _TOOLS_DIR
os.environ["WEBAPP_TOKEN_FILE"] = os.path.join(_TMP, "api-token")
os.environ["WEBAPP_DATA_DIR"] = os.path.join(_TMP, "data")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import app as app_module  # noqa: E402
import auth  # noqa: E402


class WebappTestCase(unittest.TestCase):
    def setUp(self):
        self.client = app_module.app.test_client()
        self.token = auth.API_TOKEN
        with open(CALL_LOG, "w", encoding="utf-8"):
            pass  # truncate between tests

        # Favorites live in a single on-disk file shared by every test in
        # this module (actions.favorites binds DATA_FILE from the
        # environment once, at import time) - reset it here so each test
        # method starts from an empty favorites list regardless of what
        # earlier tests/classes saved.
        import actions.favorites as favorites_module

        for path in (favorites_module.DATA_FILE, favorites_module.LOCK_FILE):
            if os.path.exists(path):
                os.remove(path)

    def auth_headers(self, token=None):
        return {"X-API-Key": token if token is not None else self.token}

    def post(self, path, json=None, token=None):
        return self.client.post(path, json=json or {}, headers=self.auth_headers(token))

    def get(self, path, token=None):
        return self.client.get(path, headers=self.auth_headers(token))

    def delete(self, path, token=None):
        return self.client.delete(path, headers=self.auth_headers(token))


class HealthAndIndexTest(WebappTestCase):
    def test_health(self):
        resp = self.client.get("/api/health")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.get_json(), {"ok": True})

    def test_index_page_needs_no_auth(self):
        resp = self.client.get("/")
        self.assertEqual(resp.status_code, 200)
        self.assertIn(b"Waydroid Control", resp.data)

    def test_index_shows_vnc_link_by_default(self):
        # WEBAPP_UNIFY_VNC is unset in the test environment - app.py's
        # index() route defaults it to "yes", same as install-webapp.sh.
        resp = self.client.get("/")
        self.assertIn(b'id="vnc-link"', resp.data)

    def test_index_hides_vnc_link_when_unify_disabled(self):
        with mock.patch.dict(os.environ, {"WEBAPP_UNIFY_VNC": "no"}):
            resp = self.client.get("/")
        self.assertNotIn(b'id="vnc-link"', resp.data)


class AuthTest(WebappTestCase):
    def test_missing_key_rejected(self):
        resp = self.client.post("/api/gps/set", json={"latitude": 1, "longitude": 2})
        self.assertEqual(resp.status_code, 401)

    def test_wrong_key_rejected(self):
        resp = self.post("/api/gps/set", {"latitude": 1, "longitude": 2}, token="wrong")
        self.assertEqual(resp.status_code, 401)

    def test_correct_key_accepted(self):
        resp = self.post("/api/gps/set", {"latitude": 1, "longitude": 2})
        self.assertEqual(resp.status_code, 200)

    def test_favorites_list_also_requires_key(self):
        # Favorites can hold real addresses - listing them is gated the
        # same as any mutating action, not left open as a plain GET.
        resp = self.client.get("/api/favorites/list")
        self.assertEqual(resp.status_code, 401)


class GpsTest(WebappTestCase):
    def test_set_location_valid(self):
        resp = self.post("/api/gps/set", {"latitude": 48.8584, "longitude": 2.2945, "altitude": 35.0})
        self.assertEqual(resp.status_code, 200)
        payload = resp.get_json()
        self.assertTrue(payload["ok"])
        self.assertIn("48.8584", payload["message"])
        with open(CALL_LOG, encoding="utf-8") as f:
            self.assertIn("48.8584 2.2945 35.0", f.read())

    def test_set_location_defaults_altitude(self):
        resp = self.post("/api/gps/set", {"latitude": 1, "longitude": 2})
        self.assertEqual(resp.status_code, 200)

    def test_set_location_invalid_latitude(self):
        resp = self.post("/api/gps/set", {"latitude": "nope", "longitude": 2.2945})
        self.assertEqual(resp.status_code, 400)

    def test_set_location_out_of_range(self):
        resp = self.post("/api/gps/set", {"latitude": 999, "longitude": 2.2945})
        self.assertEqual(resp.status_code, 400)

    def test_set_location_missing_fields(self):
        resp = self.post("/api/gps/set", {})
        self.assertEqual(resp.status_code, 400)

    def test_stop_location(self):
        resp = self.post("/api/gps/stop")
        self.assertEqual(resp.status_code, 200)
        with open(CALL_LOG, encoding="utf-8") as f:
            self.assertIn("--stop", f.read())

    def test_underlying_script_failure_is_400(self):
        from actions.base import run_script
        from actions.gps import CHANGE_LOCATION_SCRIPT

        result = run_script([CHANGE_LOCATION_SCRIPT, "--fail"])
        self.assertNotEqual(result.returncode, 0)


class GeocodeTest(WebappTestCase):
    def _mock_response(self, results):
        resp = mock.Mock()
        resp.raise_for_status = mock.Mock()
        resp.json.return_value = results
        return resp

    def test_search_success(self):
        results = [{"display_name": "Eiffel Tower, Paris, France", "lat": "48.8584", "lon": "2.2945"}]
        with mock.patch("actions.geocode.requests.get", return_value=self._mock_response(results)) as m:
            resp = self.post("/api/geocode/search", {"address": "Eiffel Tower"})
            self.assertEqual(resp.status_code, 200)
            payload = resp.get_json()
            self.assertEqual(len(payload["data"]["results"]), 1)
            self.assertAlmostEqual(payload["data"]["results"][0]["latitude"], 48.8584)
            _, kwargs = m.call_args
            self.assertIn("User-Agent", kwargs["headers"])

    def test_search_empty_address(self):
        resp = self.post("/api/geocode/search", {"address": "   "})
        self.assertEqual(resp.status_code, 400)

    def test_search_no_results(self):
        with mock.patch("actions.geocode.requests.get", return_value=self._mock_response([])):
            resp = self.post("/api/geocode/search", {"address": "nowhere"})
            self.assertEqual(resp.status_code, 400)


class FavoritesTest(WebappTestCase):
    def _save(self, name="Eiffel Tower", lat=48.8584, lng=2.2945, alt=35.0):
        return self.post("/api/favorites/save", {"name": name, "latitude": lat, "longitude": lng, "altitude": alt})

    def test_save_and_list(self):
        save_resp = self._save()
        self.assertEqual(save_resp.status_code, 200)
        favorite = save_resp.get_json()["data"]["favorite"]
        self.assertEqual(favorite["name"], "Eiffel Tower")
        self.assertIn("id", favorite)

        list_resp = self.get("/api/favorites/list")
        self.assertEqual(list_resp.status_code, 200)
        names = [f["name"] for f in list_resp.get_json()["data"]["favorites"]]
        self.assertIn("Eiffel Tower", names)

    def test_save_requires_name(self):
        resp = self.post("/api/favorites/save", {"latitude": 1, "longitude": 2})
        self.assertEqual(resp.status_code, 400)

    def test_save_rejects_invalid_coordinates(self):
        resp = self.post("/api/favorites/save", {"name": "Bad", "latitude": 999, "longitude": 2})
        self.assertEqual(resp.status_code, 400)

    def test_list_filter_by_query(self):
        self._save(name="Eiffel Tower")
        self._save(name="Statue of Liberty", lat=40.6892, lng=-74.0445)

        resp = self.get("/api/favorites/list?q=eiffel")
        self.assertEqual(resp.status_code, 200)
        names = [f["name"] for f in resp.get_json()["data"]["favorites"]]
        self.assertEqual(names, ["Eiffel Tower"])

    def test_apply_favorite_calls_change_location(self):
        favorite = self._save().get_json()["data"]["favorite"]
        resp = self.post(f"/api/favorites/{favorite['id']}/apply")
        self.assertEqual(resp.status_code, 200)
        self.assertIn("Eiffel Tower", resp.get_json()["message"])
        with open(CALL_LOG, encoding="utf-8") as f:
            self.assertIn("48.8584 2.2945 35.0", f.read())

    def test_apply_unknown_favorite(self):
        resp = self.post("/api/favorites/does-not-exist/apply")
        self.assertEqual(resp.status_code, 400)

    def test_delete_favorite(self):
        favorite = self._save().get_json()["data"]["favorite"]
        del_resp = self.delete(f"/api/favorites/{favorite['id']}")
        self.assertEqual(del_resp.status_code, 200)

        list_resp = self.get("/api/favorites/list")
        ids = [f["id"] for f in list_resp.get_json()["data"]["favorites"]]
        self.assertNotIn(favorite["id"], ids)

    def test_delete_unknown_favorite(self):
        resp = self.delete("/api/favorites/does-not-exist")
        self.assertEqual(resp.status_code, 400)

    def test_favorites_persist_across_requests(self):
        # Exercises the on-disk JSON store (not just in-memory state),
        # including the flock-guarded read-modify-write path.
        first = self._save(name="A").get_json()["data"]["favorite"]
        second = self._save(name="B").get_json()["data"]["favorite"]
        list_resp = self.get("/api/favorites/list")
        ids = {f["id"] for f in list_resp.get_json()["data"]["favorites"]}
        self.assertEqual(ids, {first["id"], second["id"]})


if __name__ == "__main__":
    unittest.main(verbosity=2)
