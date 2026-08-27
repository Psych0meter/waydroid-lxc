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
})();
