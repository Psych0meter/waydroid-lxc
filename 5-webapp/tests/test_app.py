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

import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

from PIL import Image

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
os.environ["WEBAPP_UPDATE_STATUS_FILE"] = os.path.join(_TMP, "update-status.json")
os.environ["WEBAPP_UPDATE_LOG_FILE"] = os.path.join(_TMP, "update.log")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import app as app_module  # noqa: E402
import auth  # noqa: E402
import actions.gps as gps_module  # noqa: E402
import actions.screen as screen_module  # noqa: E402
import actions.update as update_module  # noqa: E402


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

    def test_screenshot_also_requires_key(self):
        # Same reasoning as favorites/list - it's a GET but still shows
        # live device state, not left open.
        resp = self.client.get("/api/screen/screenshot")
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
        # change-location.sh's own --fail branch (see the fake script
        # above) isn't reachable through the real /api/gps/set request
        # shape (set_location() always calls it with coordinates, never
        # "--fail") - mock run_script itself to simulate a failing
        # script and confirm the route actually surfaces that as a 400,
        # not just that run_script() can return a nonzero exit code.
        failed = subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="boom")
        with mock.patch.object(gps_module, "run_script", return_value=failed):
            resp = self.post("/api/gps/set", {"latitude": 48.8584, "longitude": 2.2945})
        self.assertEqual(resp.status_code, 400)
        self.assertIn("boom", resp.get_json()["message"])


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

    def test_search_limit_is_passed_through_and_clamped(self):
        with mock.patch("actions.geocode.requests.get", return_value=self._mock_response([])) as m:
            self.post("/api/geocode/search", {"address": "Paris", "limit": 50})
            _, kwargs = m.call_args
            self.assertEqual(kwargs["params"]["limit"], 10)  # clamped to the [1, 10] range

    def test_search_invalid_limit_falls_back_to_default(self):
        with mock.patch("actions.geocode.requests.get", return_value=self._mock_response([])) as m:
            self.post("/api/geocode/search", {"address": "Paris", "limit": "not-a-number"})
            _, kwargs = m.call_args
            self.assertEqual(kwargs["params"]["limit"], 5)


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

    def test_malformed_entries_are_skipped_not_a_500(self):
        # Regression test: favorites.json is schema-valid JSON but one
        # entry is missing keys every caller indexes without a guard
        # (e.g. hand-edited, or written by code from a future/older
        # schema) - that entry should be silently dropped, not surface
        # as an uncaught KeyError/500 the first time something lists,
        # applies, or deletes favorites.
        import actions.favorites as favorites_module

        good = self._save(name="Good").get_json()["data"]["favorite"]
        os.makedirs(favorites_module.DATA_DIR, exist_ok=True)
        with open(favorites_module.DATA_FILE, "r", encoding="utf-8") as f:
            existing = json.load(f)
        existing.append({"id": "broken", "name": "Missing coordinates"})  # no lat/lng/alt
        with open(favorites_module.DATA_FILE, "w", encoding="utf-8") as f:
            json.dump(existing, f)

        list_resp = self.get("/api/favorites/list")
        self.assertEqual(list_resp.status_code, 200)
        ids = {f["id"] for f in list_resp.get_json()["data"]["favorites"]}
        self.assertEqual(ids, {good["id"]})


class ScreenTest(WebappTestCase):
    """
    actions.screen talks to a real adb server via adbutils, not a wrapped
    shell script, so it's mocked at the adbutils.adb.device_list() level
    (the one call every action funnels through via _device()) rather than
    with a fake binary the way GpsTest fakes change-location.sh.
    """

    def _mock_device(self, width=1080, height=1920):
        device = mock.MagicMock()
        device.window_size.return_value = types.SimpleNamespace(width=width, height=height)
        device.screenshot.return_value = Image.new("RGB", (2, 2), color=(255, 0, 0))
        return device

    def test_screenshot_success(self):
        device = self._mock_device()
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.get("/api/screen/screenshot")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.mimetype, "image/png")
        self.assertTrue(resp.data.startswith(b"\x89PNG"))

    def test_screenshot_no_device(self):
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[]), \
             mock.patch("actions.screen.subprocess.run"):
            resp = self.get("/api/screen/screenshot")
        self.assertEqual(resp.status_code, 400)
        self.assertIn("No adb device", resp.get_json()["message"])

    def test_screenshot_multiple_devices_is_an_error(self):
        devices = [self._mock_device(), self._mock_device()]
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=devices):
            resp = self.get("/api/screen/screenshot")
        self.assertEqual(resp.status_code, 400)
        self.assertIn("expected exactly one", resp.get_json()["message"])

    def test_reconnect_attempted_when_no_device_initially(self):
        # device_list() returns [] the first time (triggers a reconnect
        # attempt via 'waydroid adb connect'), then a device the second
        # time - simulates a container that just came back after a
        # restart. Only reconnects once - never on the fast/common path.
        device = self._mock_device()
        with mock.patch.object(
            screen_module.adbutils.adb, "device_list", side_effect=[[], [device]]
        ) as device_list_mock, mock.patch("actions.screen.subprocess.run") as run_mock:
            resp = self.post("/api/screen/tap", {"x": 1, "y": 1})
        self.assertEqual(resp.status_code, 200)
        run_mock.assert_called_once()
        self.assertEqual(device_list_mock.call_count, 2)

    def test_tap_success(self):
        device = self._mock_device()
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.post("/api/screen/tap", {"x": 100, "y": 200})
        self.assertEqual(resp.status_code, 200)
        device.click.assert_called_once_with(100, 200)

    def test_tap_out_of_range(self):
        device = self._mock_device(width=1080, height=1920)
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.post("/api/screen/tap", {"x": 5000, "y": 200})
        self.assertEqual(resp.status_code, 400)

    def test_tap_rejects_coordinate_equal_to_width_or_height(self):
        # Regression test: valid pixel coordinates are [0, width-1] /
        # [0, height-1] - width/height themselves are one pixel past the
        # last valid one in each dimension, and used to be accepted.
        device = self._mock_device(width=1080, height=1920)
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.post("/api/screen/tap", {"x": 1080, "y": 200})
        self.assertEqual(resp.status_code, 400)
        device.click.assert_not_called()

    def test_swipe_success(self):
        device = self._mock_device()
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.post(
                "/api/screen/swipe",
                {"x1": 100, "y1": 200, "x2": 100, "y2": 800, "duration_ms": 250},
            )
        self.assertEqual(resp.status_code, 200)
        device.swipe.assert_called_once_with(100, 200, 100, 800, duration=0.25)

    def test_send_text_requires_nonempty(self):
        device = self._mock_device()
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.post("/api/screen/text", {"text": "   "})
        self.assertEqual(resp.status_code, 400)

    def test_send_text_success(self):
        device = self._mock_device()
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.post("/api/screen/text", {"text": "hello"})
        self.assertEqual(resp.status_code, 200)
        device.send_keys.assert_called_once_with("hello")

    def test_send_key_invalid(self):
        device = self._mock_device()
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.post("/api/screen/key", {"key": "nope"})
        self.assertEqual(resp.status_code, 400)

    def test_send_key_valid(self):
        device = self._mock_device()
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.post("/api/screen/key", {"key": "back"})
        self.assertEqual(resp.status_code, 200)
        device.keyevent.assert_called_once_with(4)

    def test_send_key_keyboard_passthrough_keys(self):
        # Covers the keys static/js/app.js's live host-keyboard capture
        # sends via /api/screen/key (control keys - printable characters
        # go through /api/screen/text instead, already covered above).
        device = self._mock_device()
        expected = {
            "tab": 61,
            "space": 62,
            "escape": 111,
            "delete": 112,
            "up": 19,
            "down": 20,
            "left": 21,
            "right": 22,
        }
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            for key, code in expected.items():
                device.keyevent.reset_mock()
                resp = self.post("/api/screen/key", {"key": key})
                self.assertEqual(resp.status_code, 200, key)
                device.keyevent.assert_called_once_with(code)

    def test_send_text_single_space_is_rejected(self):
        # A literal space typed via the live keyboard has to go through
        # /api/screen/key {"key": "space"} instead (see actions/screen.py)
        # - send_text() intentionally rejects whitespace-only text (it's
        # the guard against submitting a blank "Send text" field).
        device = self._mock_device()
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.post("/api/screen/text", {"text": " "})
        self.assertEqual(resp.status_code, 400)

    def test_kill_all_force_stops_every_third_party_package(self):
        device = self._mock_device()
        device.shell.return_value = (
            "package:com.example.one\npackage:com.example.two\n"
        )
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.post("/api/screen/kill-all")
        self.assertEqual(resp.status_code, 200)
        payload = resp.get_json()
        self.assertEqual(payload["data"]["stopped"], ["com.example.one", "com.example.two"])
        self.assertIn("2", payload["message"])
        device.shell.assert_any_call("pm list packages -3")
        device.shell.assert_any_call(["am", "force-stop", "com.example.one"])
        device.shell.assert_any_call(["am", "force-stop", "com.example.two"])

    def test_kill_all_with_no_third_party_packages(self):
        device = self._mock_device()
        device.shell.return_value = ""
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.post("/api/screen/kill-all")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.get_json()["data"]["stopped"], [])

    def test_kill_all_skips_a_package_that_fails_to_stop(self):
        # One stubborn package failing to force-stop shouldn't block the
        # rest - the response reports whatever actually succeeded.
        device = self._mock_device()

        def fake_shell(cmdargs):
            if cmdargs == "pm list packages -3":
                return "package:com.example.one\npackage:com.example.two\n"
            if cmdargs == ["am", "force-stop", "com.example.one"]:
                raise screen_module.adbutils.AdbError("boom")
            return ""

        device.shell.side_effect = fake_shell
        with mock.patch.object(screen_module.adbutils.adb, "device_list", return_value=[device]):
            resp = self.post("/api/screen/kill-all")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.get_json()["data"]["stopped"], ["com.example.two"])


class UpdateTest(WebappTestCase):
    """
    actions.update shells out to update-webapp.sh rather than talking to
    GitHub itself, so it's mocked at the subprocess level: subprocess.run
    (check_update - synchronous, bounded) and subprocess.Popen
    (apply_update - detached, fire-and-forget). get_status() just reads
    STATUS_FILE directly, so those tests write it by hand.
    """

    def setUp(self):
        super().setUp()
        if os.path.exists(update_module.STATUS_FILE):
            os.remove(update_module.STATUS_FILE)

    def _fake_check_result(self, stdout, stderr=""):
        result = mock.MagicMock()
        result.stdout = stdout
        result.stderr = stderr
        return result

    def test_check_requires_key(self):
        resp = self.client.get("/api/update/check")
        self.assertEqual(resp.status_code, 401)

    def test_apply_requires_key(self):
        resp = self.client.post("/api/update/apply")
        self.assertEqual(resp.status_code, 401)

    def test_status_requires_key(self):
        resp = self.client.get("/api/update/status")
        self.assertEqual(resp.status_code, 401)

    def test_check_reports_update_available(self):
        fake = self._fake_check_result(
            '{"current": "aaa", "latest": "bbb", "ref": "main", "update_available": true}\n'
        )
        with mock.patch.object(update_module.subprocess, "run", return_value=fake):
            resp = self.get("/api/update/check")
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()["data"]
        self.assertTrue(data["update_available"])
        self.assertEqual(data["current"], "aaa")
        self.assertEqual(data["latest"], "bbb")

    def test_check_reports_up_to_date(self):
        fake = self._fake_check_result(
            '{"current": "aaa", "latest": "aaa", "ref": "main", "update_available": false}\n'
        )
        with mock.patch.object(update_module.subprocess, "run", return_value=fake):
            resp = self.get("/api/update/check")
        self.assertFalse(resp.get_json()["data"]["update_available"])

    def test_check_surfaces_script_error(self):
        fake = self._fake_check_result('{"error": "failed to clone https://example/repo.git (main)"}\n')
        with mock.patch.object(update_module.subprocess, "run", return_value=fake):
            resp = self.get("/api/update/check")
        self.assertEqual(resp.status_code, 400)
        self.assertIn("failed to clone", resp.get_json()["message"])

    def test_check_surfaces_non_json_output_as_error(self):
        fake = self._fake_check_result("", stderr="git: command not found")
        with mock.patch.object(update_module.subprocess, "run", return_value=fake):
            resp = self.get("/api/update/check")
        self.assertEqual(resp.status_code, 400)
        self.assertIn("git: command not found", resp.get_json()["message"])

    def test_apply_starts_a_detached_background_process(self):
        with mock.patch.object(update_module.subprocess, "Popen", return_value=mock.Mock(pid=12345)) as popen:
            resp = self.post("/api/update/apply")
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.get_json()["ok"])
        popen.assert_called_once()
        args, kwargs = popen.call_args
        self.assertEqual(args[0], [update_module.UPDATE_SCRIPT])
        # The whole point: it has to survive this process (and the
        # systemd service it runs under) being killed mid-update.
        self.assertTrue(kwargs.get("start_new_session"))

    def test_apply_writes_running_status_before_the_process_even_starts(self):
        # Regression test: apply_update() must write "running" itself,
        # synchronously, rather than leaving that to update-webapp.sh -
        # otherwise a status poll landing before the (mocked-here-as-a-
        # no-op) background process has actually run would still see
        # whatever STATUS_FILE held from a previous run (e.g. a stale
        # "success") and misreport it as this run's outcome. Popen is
        # mocked to do nothing but return a pid, so if this file ends up
        # "running" it can only be because apply_update() wrote it
        # directly.
        with open(update_module.STATUS_FILE, "w", encoding="utf-8") as f:
            f.write('{"state": "success", "from": "old", "to": "stale"}')
        with mock.patch.object(update_module.subprocess, "Popen", return_value=mock.Mock(pid=12345)):
            self.post("/api/update/apply")
        resp = self.get("/api/update/status")
        self.assertEqual(resp.get_json()["data"]["state"], "running")

    def test_apply_refuses_a_second_run_while_one_is_in_progress(self):
        with open(update_module.STATUS_FILE, "w", encoding="utf-8") as f:
            f.write('{"state": "running", "pid": 999999}')
        with mock.patch.object(update_module, "_pid_is_running", return_value=True), \
             mock.patch.object(update_module.subprocess, "Popen") as popen:
            resp = self.post("/api/update/apply")
        self.assertEqual(resp.status_code, 400)
        self.assertIn("already in progress", resp.get_json()["message"])
        popen.assert_not_called()

    def test_apply_allows_a_new_run_once_the_previous_pid_is_no_longer_running(self):
        # Regression test: a "running" status left behind by a process
        # that died without ever updating it - a host reboot, an OOM
        # kill, `kill -9` by hand, or (before waydroid-webapp.service's
        # KillMode=process) being caught by its own `systemctl restart`
        # mid-update - must not permanently block every future update
        # with "An update is already in progress."
        with open(update_module.STATUS_FILE, "w", encoding="utf-8") as f:
            f.write('{"state": "running", "pid": 999999}')
        with mock.patch.object(update_module, "_pid_is_running", return_value=False), \
             mock.patch.object(update_module.subprocess, "Popen", return_value=mock.Mock(pid=12345)) as popen:
            resp = self.post("/api/update/apply")
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.get_json()["ok"])
        popen.assert_called_once()

    def test_pid_is_running_rejects_nonexistent_pid(self):
        self.assertFalse(update_module._pid_is_running(999999999))

    def test_pid_is_running_rejects_non_int(self):
        self.assertFalse(update_module._pid_is_running(None))
        self.assertFalse(update_module._pid_is_running("not-a-pid"))

    def test_pid_is_running_rejects_a_live_pid_that_isnt_update_webapp_sh(self):
        # The test process itself is definitely alive, but it isn't
        # update-webapp.sh - this is the pid-reuse guard: a stale
        # STATUS_FILE naming a pid some unrelated process now holds
        # must not be mistaken for the original run still going.
        self.assertFalse(update_module._pid_is_running(os.getpid()))

    def test_status_is_idle_with_no_status_file(self):
        resp = self.get("/api/update/status")
        self.assertEqual(resp.get_json()["data"], {"state": "idle"})

    def test_status_reflects_the_status_file(self):
        with open(update_module.STATUS_FILE, "w", encoding="utf-8") as f:
            f.write('{"state": "success", "from": "aaa", "to": "bbb", "ref": "main"}')
        resp = self.get("/api/update/status")
        data = resp.get_json()["data"]
        self.assertEqual(data["state"], "success")
        self.assertEqual(data["to"], "bbb")

    def test_status_falls_back_to_idle_on_corrupt_status_file(self):
        # A status file caught mid-write by update-webapp.sh (it writes
        # via a tmp-file-then-mv, so this should be rare, but a reader
        # shouldn't ever 500 over it) should read as idle, not crash.
        with open(update_module.STATUS_FILE, "w", encoding="utf-8") as f:
            f.write("{not valid json")
        resp = self.get("/api/update/status")
        self.assertEqual(resp.get_json()["data"], {"state": "idle"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
