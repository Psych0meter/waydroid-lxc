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
  const apiKeyDialogMessage = document.getElementById("api-key-dialog-message");
  const updateBtn = document.getElementById("update-btn");
  const updateDialog = document.getElementById("update-dialog");
  const updateDialogTitle = document.getElementById("update-dialog-title");
  const updateDialogMessage = document.getElementById("update-dialog-message");
  const updateConfirmBtn = document.getElementById("update-confirm-btn");
  const updateCancelBtn = document.getElementById("update-cancel-btn");
  const updateCloseBtn = document.getElementById("update-close-btn");

  function getApiKey() {
    return window.localStorage.getItem(API_KEY_STORAGE_KEY) || "";
  }

  function setApiKey(value) {
    window.localStorage.setItem(API_KEY_STORAGE_KEY, value);
  }

  function setStatus(message, kind) {
    statusEl.textContent = message;
    statusEl.className = "status-line " + (kind || "");
  }

  // Surfaces a missing/invalid API key as a popup rather than relying on
  // the small inline status lines, which are easy to miss (especially
  // with the Screen panel filling most of the viewport). Safe to call
  // repeatedly while already open - it just updates the message in place
  // instead of stealing focus with a second showModal().
  function openApiKeyDialog(message, kind) {
    if (message) {
      apiKeyDialogMessage.textContent = message;
      apiKeyDialogMessage.className = "status-line " + (kind || "error");
      apiKeyDialogMessage.hidden = false;
    } else {
      apiKeyDialogMessage.hidden = true;
    }
    apiKeyInput.value = getApiKey();
    // Reset returnValue before showing: a <form method="dialog"> submit
    // only overwrites returnValue when its submitter has an explicit
    // value attribute, so without this a dialog previously closed via
    // Cancel (returnValue "cancel") would otherwise still read as
    // cancelled the next time it's saved, and the key would silently
    // never be stored.
    apiKeyDialog.returnValue = "";
    if (!apiKeyDialog.open) apiKeyDialog.showModal();
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
        openApiKeyDialog("API key missing or invalid.");
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

  // Collapses #location-body (see app.css) - map, address search,
  // coordinates, and favorites alike - to just the header row, for
  // screen space when you're not actively picking a location. Persisted
  // across reloads the same way the API key is.
  const mapPanel = document.getElementById("map-panel");
  const mapToggleBtn = document.getElementById("map-toggle-btn");
  const MAP_COLLAPSED_STORAGE_KEY = "waydroid-map-collapsed";

  function setMapCollapsed(collapsed) {
    mapPanel.classList.toggle("collapsed", collapsed);
    const label = collapsed ? "Expand Location" : "Collapse Location";
    mapToggleBtn.textContent = collapsed ? "▸" : "▾";
    mapToggleBtn.title = label;
    mapToggleBtn.setAttribute("aria-label", label);
    window.localStorage.setItem(MAP_COLLAPSED_STORAGE_KEY, collapsed ? "1" : "0");
    if (!collapsed) {
      // The map was just laid out under display:none, so Leaflet
      // measured a zero-size container - invalidateSize() re-measures
      // it now that it's visible, otherwise tiles render cropped/blank
      // until the next manual pan/zoom.
      window.requestAnimationFrame(() => map.invalidateSize());
    }
  }

  mapToggleBtn.addEventListener("click", () => {
    setMapCollapsed(!mapPanel.classList.contains("collapsed"));
  });

  if (window.localStorage.getItem(MAP_COLLAPSED_STORAGE_KEY) === "1") setMapCollapsed(true);

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
      deleteBtn.setAttribute("aria-label", `Delete "${fav.name}"`);
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
      // Non-fatal: keep whatever was already rendered.
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
    openApiKeyDialog();
  });
  document.getElementById("api-key-cancel").addEventListener("click", () => {
    apiKeyDialog.close("cancel");
  });
  apiKeyDialog.addEventListener("close", () => {
    if (apiKeyDialog.returnValue !== "cancel") {
      setApiKey(apiKeyInput.value.trim());
      loadFavorites();
      startUpdateChecks();
    }
  });

  // --- Self-update ------------------------------------------------------
  // Checking hits GitHub (a shallow git clone via update-webapp.sh), so
  // it's a real network call, not instant - see actions/update.py.
  // Applying restarts the webapp's own systemd service partway through,
  // so the dialog can't just await one request: it starts the update,
  // then polls /api/update/status (surviving the restart from the
  // browser's side) until update-webapp.sh reports success or failure.
  let pendingUpdateData = null;
  let dismissedUpdateVersion = null;
  let updatePolling = false;

  function shortVersion(v) {
    return v && v.length > 7 ? v.slice(0, 7) : v || "unknown";
  }

  function showUpdateAvailable(data) {
    pendingUpdateData = data;
    updateDialogTitle.textContent = "Update available";
    updateDialogMessage.textContent =
      `Installed ${shortVersion(data.current)} -> latest ${shortVersion(data.latest)} (${data.ref}). Update now?`;
    updateDialogMessage.className = "status-line";
    updateConfirmBtn.hidden = false;
    updateCancelBtn.hidden = false;
    updateCloseBtn.hidden = true;
    if (!updateDialog.open) updateDialog.showModal();
  }

  function showUpdateMessage(title, message, kind) {
    updateDialogTitle.textContent = title;
    updateDialogMessage.textContent = message;
    updateDialogMessage.className = "status-line " + (kind || "");
    updateConfirmBtn.hidden = true;
    updateCancelBtn.hidden = true;
    updateCloseBtn.hidden = false;
    if (!updateDialog.open) updateDialog.showModal();
  }

  async function fetchUpdateCheck() {
    const result = await apiRequest("GET", "/api/update/check");
    return result.data || {};
  }

  // Runs silently on load and periodically - a failed background check
  // (e.g. the container has no network access to GitHub right now)
  // shouldn't interrupt the user; the Update button still works for an
  // explicit, visible retry. Only pops the dialog automatically the
  // first time a given commit is seen, so "Not now" isn't immediately
  // re-asked by the next periodic check.
  async function autoCheckForUpdate() {
    if (updatePolling) return;
    try {
      const data = await fetchUpdateCheck();
      updateBtn.classList.toggle("has-update", !!data.update_available);
      if (data.update_available && data.latest !== dismissedUpdateVersion) {
        showUpdateAvailable(data);
      }
    } catch (err) {
      // Silent - see comment above.
    }
  }

  updateBtn.addEventListener("click", async () => {
    showUpdateMessage("Update", "Checking for updates...", "");
    updateCloseBtn.hidden = true;
    try {
      const data = await fetchUpdateCheck();
      updateBtn.classList.toggle("has-update", !!data.update_available);
      if (data.update_available) {
        showUpdateAvailable(data);
      } else {
        showUpdateMessage("Update", `Already up to date (${shortVersion(data.current)}).`, "ok");
      }
    } catch (err) {
      showUpdateMessage("Update", err.message, "error");
    }
  });

  updateCancelBtn.addEventListener("click", () => {
    if (pendingUpdateData) dismissedUpdateVersion = pendingUpdateData.latest;
    updateDialog.close();
  });
  updateCloseBtn.addEventListener("click", () => {
    updateDialog.close();
  });

  updateConfirmBtn.addEventListener("click", async () => {
    updateConfirmBtn.hidden = true;
    updateCancelBtn.hidden = true;
    updateDialogTitle.textContent = "Updating...";
    updateDialogMessage.textContent =
      "This can take a minute - the webapp will restart automatically. Keep this tab open.";
    updateDialogMessage.className = "status-line";
    try {
      await apiPost("/api/update/apply", {});
    } catch (err) {
      showUpdateMessage("Update failed", err.message, "error");
      return;
    }
    pollUpdateStatus();
  });

  function pollUpdateStatus() {
    if (updatePolling) return;
    updatePolling = true;
    const deadline = Date.now() + 3 * 60 * 1000;

    const poll = async () => {
      if (Date.now() > deadline) {
        updatePolling = false;
        showUpdateMessage(
          "Update",
          "Taking longer than expected. Check the container (journalctl -u waydroid-webapp) or reload the page.",
          "error"
        );
        return;
      }
      let status = null;
      try {
        const result = await apiRequest("GET", "/api/update/status");
        status = result.data;
      } catch (err) {
        // Expected while the service is restarting - keep polling.
      }
      if (status && status.state === "success") {
        updatePolling = false;
        updateBtn.classList.remove("has-update");
        updateDialogTitle.textContent = "Update complete";
        updateDialogMessage.textContent = `Updated to ${shortVersion(status.to)}. Reloading...`;
        updateDialogMessage.className = "status-line ok";
        window.setTimeout(() => window.location.reload(), 1200);
        return;
      }
      if (status && status.state === "failed") {
        updatePolling = false;
        showUpdateMessage(
          "Update failed",
          `${status.error || "Unknown error"} - rolled back to the previous version.`,
          "error"
        );
        return;
      }
      window.setTimeout(poll, 1500);
    };
    poll();
  }

  let updateChecksStarted = false;
  function startUpdateChecks() {
    if (updateChecksStarted) return;
    updateChecksStarted = true;
    autoCheckForUpdate();
    window.setInterval(() => {
      if (getApiKey()) autoCheckForUpdate();
    }, 60 * 60 * 1000);
  }

  if (!getApiKey()) {
    openApiKeyDialog("Set your API key to use this webapp.", "");
  } else {
    loadFavorites();
    startUpdateChecks();
  }

  // --- Screen (see README, "Screen: remote control") --------------------
  const screenImg = document.getElementById("screen-img");
  const screenToggleBtn = document.getElementById("screen-toggle-btn");
  const screenStatusEl = document.getElementById("screen-status");
  const screenTextForm = document.getElementById("screen-text-form");
  const screenTextInput = document.getElementById("screen-text-input");
  const screenRefreshRange = document.getElementById("screen-refresh-rate");
  const screenRefreshValueEl = document.getElementById("screen-refresh-value");
  const screenRefreshIndicatorEl = document.getElementById("screen-refresh-indicator");
  const screenRealtimeToggle = document.getElementById("screen-realtime-toggle");
  const screenLockStatusEl = document.getElementById("screen-lock-status");
  const screenLockOverlay = document.getElementById("screen-lock-overlay");
  const screenLockBtn = document.getElementById("screen-lock-btn");
  const screenUnlockPinInput = document.getElementById("screen-unlock-pin-input");
  const screenUnlockBtn = document.getElementById("screen-unlock-btn");
  const screenSetPinForm = document.getElementById("screen-set-pin-form");
  const screenNewPinInput = document.getElementById("screen-new-pin-input");
  const screenOldPinInput = document.getElementById("screen-old-pin-input");

  let screenPolling = false;
  let screenTimer = null;
  let screenObjectUrl = null;
  let dragStart = null;
  let lockStatusTimer = null;

  // Poll rate: a fast "active" rate for a few seconds after an
  // interaction, decaying to a slower "idle" rate set by the drag bar.
  // "Real-time" overrides both with continuous back-to-back polling.
  const ACTIVE_POLL_INTERVAL_MS = 250;
  const ACTIVE_WINDOW_MS = 4000;
  // Separate, much slower than the screenshot poll - lock-status is its
  // own dumpsys call, not free, and doesn't need to track activity.
  const LOCK_STATUS_POLL_MS = 3000;
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

  // Switches to the active poll rate immediately by re-arming the timer,
  // instead of waiting for the next already-scheduled poll to fire.
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

  // Icon-only button (see templates/index.html) - swaps both the glyph
  // and the title/aria-label together, since there's no visible text
  // left to imply which action a bare "■" or "▶" means.
  function setScreenToggleLabel(running) {
    screenToggleBtn.textContent = running ? "■" : "▶"; // ■ stop-square, ▶ play-triangle
    const label = running ? "Stop screen" : "Start screen";
    screenToggleBtn.title = label;
    screenToggleBtn.setAttribute("aria-label", label);
  }

  function setScreenStatus(message, kind) {
    screenStatusEl.textContent = message;
    screenStatusEl.className = "status-line " + (kind || "");
  }

  // Fetched with the API key header (an <img src> can't set one) and
  // turned into an object URL; the previous URL is revoked each time to
  // avoid leaking a blob per screenshot.
  async function fetchScreenshot() {
    const response = await fetch("/api/screen/screenshot", {
      headers: { "X-API-Key": getApiKey() },
    });
    if (!response.ok) {
      const payload = await response.json().catch(() => ({}));
      const message = payload.message || `Screenshot failed (${response.status})`;
      if (response.status === 401) openApiKeyDialog(message);
      throw new Error(message);
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
      // Avoid a tight 0ms retry loop in real-time mode after a failure.
      const delay = failed && realtimeMode ? ACTIVE_POLL_INTERVAL_MS : currentPollInterval();
      screenTimer = window.setTimeout(pollScreen, delay);
    }
  }

  // Polled independently of the screenshot loop (see LOCK_STATUS_POLL_MS)
  // so a stuck/failing screenshot doesn't also freeze the lock indicator
  // - the indicator (and the overlay/button states below) are most
  // useful exactly when the screen itself can't be captured.
  async function pollLockStatus() {
    if (!screenPolling) return;
    try {
      const result = await apiRequest("GET", "/api/screen/lock-status");
      const locked = !!(result.data && result.data.locked);
      screenLockStatusEl.textContent = "Lock: " + (locked ? "locked" : "unlocked");
      screenLockStatusEl.className = locked ? "locked" : "unlocked";
      // See app.css's #screen-lock-overlay for why this exists.
      screenLockOverlay.classList.toggle("visible", locked);
      // Grey out whichever action is already the current state.
      screenLockBtn.disabled = locked;
      screenUnlockBtn.disabled = !locked;
    } catch (err) {
      // Unknown state - leave both actions available rather than
      // risking either one stuck disabled on a transient error.
      screenLockStatusEl.textContent = "Lock: ?";
      screenLockStatusEl.className = "";
      screenLockBtn.disabled = false;
      screenUnlockBtn.disabled = false;
    }
    if (screenPolling) lockStatusTimer = window.setTimeout(pollLockStatus, LOCK_STATUS_POLL_MS);
  }

  function startScreen() {
    if (screenPolling) return;
    if (!getApiKey()) {
      openApiKeyDialog("Set your API key to start the screen.");
      return;
    }
    screenPolling = true;
    setScreenToggleLabel(true);
    lastActivityAt = Date.now(); // start at the active rate
    lastFrameAt = null;
    lastFrameIntervalMs = null;
    pollScreen();
    pollLockStatus();
  }

  function stopScreen() {
    screenPolling = false;
    if (screenTimer) window.clearTimeout(screenTimer);
    if (lockStatusTimer) window.clearTimeout(lockStatusTimer);
    setScreenToggleLabel(false);
    // Hides the last frame rather than leaving it frozen on screen -
    // removing the attribute (not just clearing it) is what the
    // #screen-img[src] CSS rule keys off of to hide the element.
    if (screenObjectUrl) {
      URL.revokeObjectURL(screenObjectUrl);
      screenObjectUrl = null;
    }
    screenImg.removeAttribute("src");
    screenImg.alt = "Waydroid screen (not started)";
    screenImg.blur();
    dragStart = null;
    screenLockStatusEl.textContent = "Lock: -";
    screenLockStatusEl.className = "";
    screenLockOverlay.classList.remove("visible");
    screenLockBtn.disabled = false;
    screenUnlockBtn.disabled = false;
    updateRefreshIndicator();
  }

  screenToggleBtn.addEventListener("click", () => {
    if (screenPolling) stopScreen();
    else startScreen();
  });

  // Converts a pointer event's browser-pixel position to device-pixel
  // coordinates, scaling by the ratio between the image's natural size
  // and its displayed size.
  function toDeviceCoords(event) {
    const rect = screenImg.getBoundingClientRect();
    const scaleX = screenImg.naturalWidth / rect.width;
    const scaleY = screenImg.naturalHeight / rect.height;
    return {
      x: Math.round((event.clientX - rect.left) * scaleX),
      y: Math.round((event.clientY - rect.top) * scaleY),
    };
  }

  // <img> elements are natively draggable, which hijacks swipe gestures
  // (fires 'dragstart' then 'pointercancel', so 'pointerup' never
  // arrives) - disabled both via the attribute and preventDefault(),
  // since the attribute alone isn't reliable across browsers.
  screenImg.draggable = false;
  screenImg.addEventListener("dragstart", (event) => event.preventDefault());

  screenImg.addEventListener("pointerdown", (event) => {
    if (!screenPolling) return;
    markActivity();
    screenImg.focus(); // arms the keydown listener below; see CSS :focus
    dragStart = toDeviceCoords(event);
    screenImg.classList.add("dragging"); // grab -> grabbing, same as the map
    // Keeps pointermove/pointerup targeting this element even if the
    // drag overshoots its bounds.
    screenImg.setPointerCapture(event.pointerId);
  });

  screenImg.addEventListener("pointercancel", () => {
    dragStart = null;
    screenImg.classList.remove("dragging");
  });

  screenImg.addEventListener("pointerup", async (event) => {
    screenImg.classList.remove("dragging");
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

  document.getElementById("screen-kill-all-btn").addEventListener("click", async () => {
    markActivity();
    try {
      const result = await apiPost("/api/screen/kill-all", {});
      setScreenStatus(result.message || "Killed all apps.", "ok");
      fetchScreenshot();
    } catch (err) {
      setScreenStatus(err.message, "error");
    }
  });

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

  screenLockBtn.addEventListener("click", async () => {
    markActivity();
    try {
      const result = await apiPost("/api/screen/lock", {});
      setScreenStatus(result.message || "Locked.", "ok");
      pollLockStatus();
      fetchScreenshot();
    } catch (err) {
      setScreenStatus(err.message, "error");
    }
  });

  screenUnlockBtn.addEventListener("click", async () => {
    const pin = screenUnlockPinInput.value;
    if (!pin) return;
    markActivity();
    try {
      const result = await apiPost("/api/screen/unlock", { pin });
      setScreenStatus(result.message || "PIN entered.", "ok");
      screenUnlockPinInput.value = "";
      pollLockStatus();
      fetchScreenshot();
    } catch (err) {
      setScreenStatus(err.message, "error");
    }
  });

  screenSetPinForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const pin = screenNewPinInput.value;
    const oldPin = screenOldPinInput.value;
    if (!pin) return;
    markActivity();
    try {
      const result = await apiPost("/api/screen/set-pin", {
        pin,
        old_pin: oldPin || undefined,
      });
      setScreenStatus(result.message || "PIN set.", "ok");
      screenNewPinInput.value = "";
      screenOldPinInput.value = "";
    } catch (err) {
      setScreenStatus(err.message, "error");
    }
  });

  // --- Host-keyboard passthrough -----------------------------------------
  // Scoped to keydown on the image itself (focused via pointerdown above),
  // so it never intercepts keystrokes meant for other fields. Control
  // keys (and digits - see below) map to /api/screen/key by event.code
  // (layout-independent); other printable characters go to
  // /api/screen/text via event.key, which already accounts for
  // Shift/layout.
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
    // Real KeyEvents, not /api/screen/text's synthetic text injection -
    // the one thing that reliably reaches a lock-screen PIN pad (see
    // actions/screen.py's send_text() docstring), so typing a PIN here
    // works even completely blind, with no working screenshot at all.
    Digit0: "0", Digit1: "1", Digit2: "2", Digit3: "3", Digit4: "4",
    Digit5: "5", Digit6: "6", Digit7: "7", Digit8: "8", Digit9: "9",
    Numpad0: "0", Numpad1: "1", Numpad2: "2", Numpad3: "3", Numpad4: "4",
    Numpad5: "5", Numpad6: "6", Numpad7: "7", Numpad8: "8", Numpad9: "9",
  };

  // Sent one at a time, in order, so fast typing can't reach the device
  // out of order.
  let screenKeySendQueue = Promise.resolve();
  function queueScreenKeySend(action) {
    screenKeySendQueue = screenKeySendQueue.then(action).catch((err) => {
      setScreenStatus(err.message, "error");
    });
  }

  screenImg.addEventListener("keydown", (event) => {
    if (!screenPolling) return;
    if (event.ctrlKey || event.altKey || event.metaKey) return; // leave OS/browser shortcuts alone

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
