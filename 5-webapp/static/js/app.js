(() => {
  "use strict";

  const API_KEY_STORAGE_KEY = "waydroid-webapp-api-key";

  const statusEl = document.getElementById("status");
  const latInput = document.getElementById("latitude");
  const lngInput = document.getElementById("longitude");
  const altInput = document.getElementById("altitude");
  const addressInput = document.getElementById("address");
  const apiKeyDialog = document.getElementById("api-key-dialog");
  const apiKeyInput = document.getElementById("api-key-input");

  function getApiKey() {
    return window.localStorage.getItem(API_KEY_STORAGE_KEY) || "";
  }

  function setApiKey(value) {
    window.localStorage.setItem(API_KEY_STORAGE_KEY, value);
  }

  function setStatus(message, kind) {
    statusEl.textContent = message;
    statusEl.className = kind || "";
  }

  async function apiRequest(method, path, body) {
    const headers = { "X-API-Key": getApiKey() };
    const options = { method, headers };
    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
      options.body = JSON.stringify(body);
    }
    const response = await fetch(path, options);
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload.ok === false) {
      const message = payload.message || `Request failed (${response.status})`;
      if (response.status === 401) {
        setStatus("API key missing or invalid - click \"API key\" above to set it.", "error");
      }
      throw new Error(message);
    }
    return payload;
  }

  function apiPost(path, body) {
    return apiRequest("POST", path, body || {});
  }

  // --- Map -------------------------------------------------------------
  const map = L.map("map").setView([48.8584, 2.2945], 5); // Eiffel Tower, zoomed out
  L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19,
    attribution: "&copy; OpenStreetMap contributors",
  }).addTo(map);

  // Vendored marker icons (see install-webapp.sh) - Leaflet's default
  // icon paths assume a bundler that rewrites image URLs, which doesn't
  // apply here, so they're pointed at explicitly.
  const markerIcon = L.icon({
    iconUrl: "static/vendor/leaflet/images/marker-icon.png",
    iconRetinaUrl: "static/vendor/leaflet/images/marker-icon-2x.png",
    shadowUrl: "static/vendor/leaflet/images/marker-shadow.png",
    iconSize: [25, 41],
    iconAnchor: [12, 41],
    popupAnchor: [1, -34],
    shadowSize: [41, 41],
  });

  let marker = null;

  function placeMarker(lat, lng, panTo) {
    if (marker) {
      marker.setLatLng([lat, lng]);
    } else {
      marker = L.marker([lat, lng], { icon: markerIcon, draggable: true }).addTo(map);
      marker.on("dragend", () => {
        const pos = marker.getLatLng();
        fillCoords(pos.lat, pos.lng);
      });
    }
    if (panTo) {
      map.setView([lat, lng], Math.max(map.getZoom(), 12));
    }
  }

  function fillCoords(lat, lng) {
    latInput.value = lat.toFixed(6);
    lngInput.value = lng.toFixed(6);
  }

  map.on("click", (event) => {
    const { lat, lng } = event.latlng;
    fillCoords(lat, lng);
    placeMarker(lat, lng, false);
  });

  // --- Address search ----------------------------------------------------
  document.getElementById("address-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const address = addressInput.value.trim();
    if (!address) return;
    setStatus("Searching...", "");
    try {
      const result = await apiPost("/api/geocode/search", { address });
      const first = result.data.results[0];
      fillCoords(first.latitude, first.longitude);
      placeMarker(first.latitude, first.longitude, true);
      setStatus(`Found: ${first.display_name}`, "ok");
    } catch (err) {
      setStatus(err.message, "error");
    }
  });

  // --- Set / stop location ----------------------------------------------
  document.getElementById("coords-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const latitude = parseFloat(latInput.value);
    const longitude = parseFloat(lngInput.value);
    const altitude = altInput.value.trim() === "" ? 35.0 : parseFloat(altInput.value);
    setStatus("Setting location...", "");
    try {
      const result = await apiPost("/api/gps/set", { latitude, longitude, altitude });
      placeMarker(latitude, longitude, true);
      setStatus(result.message, "ok");
    } catch (err) {
      setStatus(err.message, "error");
    }
  });

  document.getElementById("stop-btn").addEventListener("click", async () => {
    setStatus("Stopping...", "");
    try {
      const result = await apiPost("/api/gps/stop", {});
      setStatus(result.message, "ok");
    } catch (err) {
      setStatus(err.message, "error");
    }
  });

  // --- Favorites -----------------------------------------------------
  let allFavorites = [];
  const favoritesListEl = document.getElementById("favorites-list");
  const favoriteSearchInput = document.getElementById("favorite-search");
  const favoriteNameInput = document.getElementById("favorite-name");

  function renderFavorites() {
    const filter = favoriteSearchInput.value.trim().toLowerCase();
    const filtered = filter
      ? allFavorites.filter((fav) => fav.name.toLowerCase().includes(filter))
      : allFavorites;

    favoritesListEl.innerHTML = "";
    if (filtered.length === 0) {
      const li = document.createElement("li");
      li.className = "empty";
      li.textContent =
        allFavorites.length === 0 ? "No favorites saved yet." : "No favorites match.";
      favoritesListEl.appendChild(li);
      return;
    }

    for (const fav of filtered) {
      const li = document.createElement("li");

      const applyBtn = document.createElement("button");
      applyBtn.type = "button";
      applyBtn.className = "favorite-apply";
      applyBtn.textContent = fav.name;
      applyBtn.title = `${fav.latitude.toFixed(4)}, ${fav.longitude.toFixed(4)}`;
      applyBtn.addEventListener("click", () => applyFavorite(fav.id));

      const deleteBtn = document.createElement("button");
      deleteBtn.type = "button";
      deleteBtn.className = "favorite-delete";
      deleteBtn.textContent = "×";
      deleteBtn.title = `Delete "${fav.name}"`;
      deleteBtn.addEventListener("click", () => deleteFavorite(fav.id));

      li.appendChild(applyBtn);
      li.appendChild(deleteBtn);
      favoritesListEl.appendChild(li);
    }
  }

  async function loadFavorites() {
    try {
      const result = await apiRequest("GET", "/api/favorites/list");
      allFavorites = result.data.favorites;
      renderFavorites();
    } catch (err) {
      // Non-fatal: leave whatever was already rendered rather than
      // blocking the rest of the page over a failed favorites fetch.
      setStatus(err.message, "error");
    }
  }

  async function applyFavorite(id) {
    setStatus("Applying favorite...", "");
    try {
      const result = await apiPost(`/api/favorites/${id}/apply`);
      const fav = result.data.favorite;
      fillCoords(fav.latitude, fav.longitude);
      altInput.value = fav.altitude;
      placeMarker(fav.latitude, fav.longitude, true);
      setStatus(result.message, "ok");
    } catch (err) {
      setStatus(err.message, "error");
    }
  }

  async function deleteFavorite(id) {
    try {
      await apiRequest("DELETE", `/api/favorites/${id}`);
      await loadFavorites();
    } catch (err) {
      setStatus(err.message, "error");
    }
  }

  favoriteSearchInput.addEventListener("input", renderFavorites);

  document.getElementById("save-favorite-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const name = favoriteNameInput.value.trim();
    if (!name) {
      setStatus("Enter a name before saving a favorite.", "error");
      return;
    }
    const latitude = parseFloat(latInput.value);
    const longitude = parseFloat(lngInput.value);
    const altitude = altInput.value.trim() === "" ? 35.0 : parseFloat(altInput.value);
    if (Number.isNaN(latitude) || Number.isNaN(longitude)) {
      setStatus("Set coordinates (click the map or search an address) before saving.", "error");
      return;
    }
    try {
      const result = await apiPost("/api/favorites/save", { name, latitude, longitude, altitude });
      favoriteNameInput.value = "";
      await loadFavorites();
      setStatus(result.message, "ok");
    } catch (err) {
      setStatus(err.message, "error");
    }
  });

  // --- API key dialog ------------------------------------------------
  document.getElementById("api-key-btn").addEventListener("click", () => {
    apiKeyInput.value = getApiKey();
    apiKeyDialog.showModal();
  });
  document.getElementById("api-key-cancel").addEventListener("click", () => {
    apiKeyDialog.close();
  });
  apiKeyDialog.addEventListener("close", () => {
    if (apiKeyDialog.returnValue !== "cancel") {
      setApiKey(apiKeyInput.value.trim());
      loadFavorites();
    }
  });

  if (!getApiKey()) {
    setStatus('No API key set yet - click "API key" above before setting a location.', "");
  } else {
    loadFavorites();
  }

  // --- Screen (replaces noVNC - see README "Screen: remote control")
  const screenImg = document.getElementById("screen-img");
  const screenToggleBtn = document.getElementById("screen-toggle-btn");
  const screenStatusEl = document.getElementById("screen-status");
  const screenTextForm = document.getElementById("screen-text-form");
  const screenTextInput = document.getElementById("screen-text-input");
  const screenRefreshRange = document.getElementById("screen-refresh-rate");
  const screenRefreshValueEl = document.getElementById("screen-refresh-value");
  const screenRefreshIndicatorEl = document.getElementById("screen-refresh-indicator");
  const screenRealtimeToggle = document.getElementById("screen-realtime-toggle");

  let screenPolling = false;
  let screenTimer = null;
  let screenObjectUrl = null;
  let dragStart = null;

  // Two speeds: a fast, near-video-feed rate used for a few seconds right
  // after you actually do something (tap/swipe/key/text), and a slower
  // "just watching" rate the rest of the time - set by the drag bar. This
  // avoids hammering adb (and the CPU-constrained container) with fast
  // screencaps continuously, while still feeling responsive while in use.
  // "Real-time" (below) overrides both with continuous back-to-back
  // polling - as fast as fetch+decode allow, no fixed delay at all.
  const ACTIVE_POLL_INTERVAL_MS = 250;
  const ACTIVE_WINDOW_MS = 4000;
  let idlePollIntervalMs = parseInt(screenRefreshRange.value, 10) || 1000;
  let lastActivityAt = 0;
  let realtimeMode = false;
  let lastFrameAt = null;
  let lastFrameIntervalMs = null;

  function isBoosted() {
    return Date.now() - lastActivityAt < ACTIVE_WINDOW_MS;
  }

  function currentPollInterval() {
    if (realtimeMode) return 0;
    return isBoosted() ? ACTIVE_POLL_INTERVAL_MS : idlePollIntervalMs;
  }

  function formatSeconds(ms) {
    return (ms / 1000).toFixed(1) + "s";
  }

  function updateRefreshIndicator() {
    if (!screenPolling) {
      screenRefreshIndicatorEl.textContent = "";
      screenRefreshIndicatorEl.className = "";
      return;
    }
    if (realtimeMode) {
      const fps = lastFrameIntervalMs ? (1000 / lastFrameIntervalMs).toFixed(1) : "-";
      screenRefreshIndicatorEl.textContent = `real-time (~${fps} fps)`;
      screenRefreshIndicatorEl.className = "active";
      return;
    }
    const boosted = isBoosted();
    screenRefreshIndicatorEl.textContent = boosted
      ? `live (${formatSeconds(ACTIVE_POLL_INTERVAL_MS)})`
      : `idle (${formatSeconds(idlePollIntervalMs)})`;
    screenRefreshIndicatorEl.className = boosted ? "active" : "";
  }

  // Called on every tap/swipe/key/text: switches to the fast rate right
  // away (rather than waiting for the next already-scheduled idle-rate
  // poll to fire) by cancelling and immediately re-arming the timer.
  // No-op in real-time mode, which is already polling as fast as possible.
  function markActivity() {
    lastActivityAt = Date.now();
    updateRefreshIndicator();
    if (screenPolling && screenTimer && !realtimeMode) {
      window.clearTimeout(screenTimer);
      screenTimer = window.setTimeout(pollScreen, ACTIVE_POLL_INTERVAL_MS);
    }
  }

  screenRefreshRange.addEventListener("input", () => {
    idlePollIntervalMs = parseInt(screenRefreshRange.value, 10);
    screenRefreshValueEl.textContent = formatSeconds(idlePollIntervalMs);
    // If we're not mid-boost, apply the new idle rate immediately instead
    // of waiting out whatever interval was previously scheduled.
    if (screenPolling && screenTimer && !isBoosted()) {
      window.clearTimeout(screenTimer);
      screenTimer = window.setTimeout(pollScreen, idlePollIntervalMs);
    }
    updateRefreshIndicator();
  });
  screenRefreshValueEl.textContent = formatSeconds(idlePollIntervalMs);

  screenRealtimeToggle.addEventListener("change", () => {
    realtimeMode = screenRealtimeToggle.checked;
    screenRefreshRange.disabled = realtimeMode;
    lastFrameAt = null;
    lastFrameIntervalMs = null;
    if (screenPolling && screenTimer) {
      window.clearTimeout(screenTimer);
      screenTimer = window.setTimeout(pollScreen, 0);
    }
    updateRefreshIndicator();
  });

  function setScreenStatus(message, kind) {
    screenStatusEl.textContent = message;
    screenStatusEl.className = kind || "";
  }

  // The image is fetched with the API key header (an <img src> can't set
  // one) and turned into an object URL; the previous URL is revoked each
  // time so a long polling session doesn't leak one blob per screenshot.
  async function fetchScreenshot() {
    const response = await fetch("/api/screen/screenshot", {
      headers: { "X-API-Key": getApiKey() },
    });
    if (!response.ok) {
      const payload = await response.json().catch(() => ({}));
      throw new Error(payload.message || `Screenshot failed (${response.status})`);
    }
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    if (screenObjectUrl) URL.revokeObjectURL(screenObjectUrl);
    screenObjectUrl = url;
    screenImg.src = url;
    const now = performance.now();
    lastFrameIntervalMs = lastFrameAt !== null ? now - lastFrameAt : null;
    lastFrameAt = now;
  }

  async function pollScreen() {
    if (!screenPolling) return;
    let failed = false;
    try {
      await fetchScreenshot();
      setScreenStatus("", "");
    } catch (err) {
      failed = true;
      setScreenStatus(err.message, "error");
    }
    updateRefreshIndicator();
    if (screenPolling) {
      // In real-time mode a run of failures (e.g. the device briefly
      // disconnected) would otherwise retry in a tight 0ms loop - fall
      // back to the boosted interval instead of hammering the server.
      const delay = failed && realtimeMode ? ACTIVE_POLL_INTERVAL_MS : currentPollInterval();
      screenTimer = window.setTimeout(pollScreen, delay);
    }
  }

  function startScreen() {
    if (screenPolling) return;
    if (!getApiKey()) {
      setScreenStatus('No API key set yet - click "API key" above first.', "error");
      return;
    }
    screenPolling = true;
    screenToggleBtn.textContent = "Stop screen";
    lastActivityAt = Date.now(); // start at the fast rate, settle down after ACTIVE_WINDOW_MS
    lastFrameAt = null;
    lastFrameIntervalMs = null;
    pollScreen();
  }

  function stopScreen() {
    screenPolling = false;
    if (screenTimer) window.clearTimeout(screenTimer);
    screenToggleBtn.textContent = "Start screen";
    updateRefreshIndicator();
  }

  screenToggleBtn.addEventListener("click", () => {
    if (screenPolling) stopScreen();
    else startScreen();
  });

  // Maps a pointer event's browser-pixel position to device-pixel
  // coordinates, using the ratio between the <img>'s actual (natural)
  // size and however large it's currently being displayed - the two
  // differ whenever the screenshot is scaled to fit #screen-viewport.
  function toDeviceCoords(event) {
    const rect = screenImg.getBoundingClientRect();
    const scaleX = screenImg.naturalWidth / rect.width;
    const scaleY = screenImg.naturalHeight / rect.height;
    return {
      x: Math.round((event.clientX - rect.left) * scaleX),
      y: Math.round((event.clientY - rect.top) * scaleY),
    };
  }

  // Browsers treat an <img> as natively draggable: without this, a
  // pointerdown-then-move on the screen image starts the browser's own
  // "drag this image" gesture instead of our swipe tracking, which fires
  // a 'dragstart' and then 'pointercancel' partway through the drag - so
  // 'pointerup' never arrives and the swipe is silently dropped (taps
  // still work, since a plain click never crosses the drag threshold,
  // which is what made this easy to miss). Belt-and-suspenders: the
  // 'draggable' attribute alone isn't always enough (varies by browser),
  // so 'dragstart' is also preventDefault()'d directly.
  screenImg.draggable = false;
  screenImg.addEventListener("dragstart", (event) => event.preventDefault());

  screenImg.addEventListener("pointerdown", (event) => {
    if (!screenPolling) return;
    markActivity();
    // Gives the image keyboard focus so the keydown listener below starts
    // receiving keystrokes (tabindex="0" in the HTML makes it focusable);
    // #screen-img:focus in the CSS shows a border while this is active.
    screenImg.focus();
    dragStart = toDeviceCoords(event);
    // Pointer capture keeps pointermove/pointerup targeting this element
    // even if the drag ends up outside its bounds (e.g. a fast swipe that
    // overshoots the image edge) - without it, pointerup can land on a
    // different element (or the document) and never reach this listener.
    screenImg.setPointerCapture(event.pointerId);
  });

  screenImg.addEventListener("pointercancel", () => {
    dragStart = null;
  });

  screenImg.addEventListener("pointerup", async (event) => {
    if (!screenPolling || !dragStart) return;
    const start = dragStart;
    dragStart = null;
    const end = toDeviceCoords(event);
    const distance = Math.hypot(end.x - start.x, end.y - start.y);
    try {
      if (distance < 15) {
        await apiPost("/api/screen/tap", { x: start.x, y: start.y });
      } else {
        await apiPost("/api/screen/swipe", {
          x1: start.x,
          y1: start.y,
          x2: end.x,
          y2: end.y,
          duration_ms: 300,
        });
      }
      setScreenStatus("", "");
      fetchScreenshot();
    } catch (err) {
      setScreenStatus(err.message, "error");
    }
  });

  async function sendScreenKey(key) {
    markActivity();
    try {
      await apiPost("/api/screen/key", { key });
      setScreenStatus("", "");
      fetchScreenshot();
    } catch (err) {
      setScreenStatus(err.message, "error");
    }
  }

  document.getElementById("screen-key-back").addEventListener("click", () => sendScreenKey("back"));
  document.getElementById("screen-key-home").addEventListener("click", () => sendScreenKey("home"));
  document.getElementById("screen-key-recents").addEventListener("click", () => sendScreenKey("recents"));

  screenTextForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const text = screenTextInput.value;
    if (!text) return;
    markActivity();
    try {
      await apiPost("/api/screen/text", { text });
      screenTextInput.value = "";
      setScreenStatus("", "");
      fetchScreenshot();
    } catch (err) {
      setScreenStatus(err.message, "error");
    }
  });

  // --- Host-keyboard passthrough --------------------------------------
  // Click the screen once (pointerdown above calls screenImg.focus()) and
  // type normally - keystrokes go to whatever's focused on the device,
  // same as typing on a real keyboard plugged into it. Only fires while
  // the image itself has focus, so it never steals keystrokes meant for
  // the GPS/favorites fields, the API key dialog, or the "Send text" box.
  //
  // Physical/control keys map to /api/screen/key by event.code (layout-
  // independent - Backspace is Backspace regardless of keyboard layout).
  // Everything else that produces a single printable character is sent
  // via /api/screen/text using event.key, which already accounts for
  // Shift/layout (e.g. Shift+1 -> "!" on a US layout), so no separate
  // Shift-tracking is needed.
  const SCREEN_KEYDOWN_KEY_MAP = {
    Backspace: "backspace",
    Enter: "enter",
    NumpadEnter: "enter",
    Tab: "tab",
    Escape: "escape",
    Delete: "delete",
    ArrowUp: "up",
    ArrowDown: "down",
    ArrowLeft: "left",
    ArrowRight: "right",
    Space: "space",
  };

  // Keystrokes are queued and sent one at a time (each waiting for the
  // previous request to finish) rather than fired off in parallel, so
  // fast typing can't arrive at the device out of order.
  let screenKeySendQueue = Promise.resolve();
  function queueScreenKeySend(action) {
    screenKeySendQueue = screenKeySendQueue.then(action).catch((err) => {
      setScreenStatus(err.message, "error");
    });
  }

  screenImg.addEventListener("keydown", (event) => {
    if (!screenPolling) return;
    // Let real browser/OS shortcuts (Ctrl+C, Cmd+R, Alt+Tab, ...) through
    // untouched rather than swallowing and forwarding them as text.
    if (event.ctrlKey || event.altKey || event.metaKey) return;

    const mappedKey = SCREEN_KEYDOWN_KEY_MAP[event.code];
    if (mappedKey) {
      event.preventDefault();
      markActivity();
      queueScreenKeySend(() => apiPost("/api/screen/key", { key: mappedKey }));
      return;
    }
    if (event.key && event.key.length === 1) {
      event.preventDefault();
      markActivity();
      const ch = event.key;
      queueScreenKeySend(() => apiPost("/api/screen/text", { text: ch }));
    }
  });
})();
