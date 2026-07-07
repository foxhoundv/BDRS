const fs = require("fs");
const http = require("http");
const path = require("path");

const port = Number(process.env.PORT || 8080);
const settingsPath = process.env.CONTROL_PLANE_AUDIO_SETTINGS_FILE
  ? path.resolve(process.env.CONTROL_PLANE_AUDIO_SETTINGS_FILE)
  : path.join(__dirname, "audio-input.settings.json");
const defaultsPath = process.env.CONTROL_PLANE_AUDIO_DEFAULTS_FILE
  ? path.resolve(process.env.CONTROL_PLANE_AUDIO_DEFAULTS_FILE)
  : path.join(__dirname, "audio-input.settings.default.json");

const transportSampleRates = {
  alsa_usb: [44100, 48000],
  dante: [44100, 48000, 96000],
};

const supportedSampleFormats = ["s16_le", "s24_in_32_le"];

const wingDefaults = {
  mixerProfile: "wing",
  captureMode: "alsa",
  inputTransport: "alsa_usb",
  alsaDevice: "plughw:0,0",
  captureRateHz: 44100,
  sampleFormat: "s24_in_32_le",
  channelCount: 48,
  testChannelCount: 16,
  danteMaxSources: 64,
};

function loadDefaultSettings() {
  try {
    if (!fs.existsSync(defaultsPath)) {
      return { ...wingDefaults };
    }

    const parsed = JSON.parse(fs.readFileSync(defaultsPath, "utf8"));
    const merged = { ...wingDefaults, ...parsed };
    validateSettings(merged);
    return merged;
  } catch (error) {
    console.error(`failed to load default settings from ${defaultsPath}: ${error.message}`);
    console.error("falling back to in-code wing defaults");
    return { ...wingDefaults };
  }
}

const baselineDefaults = loadDefaultSettings();

function sendJson(res, statusCode, payload) {
  res.writeHead(statusCode, { "Content-Type": "application/json" });
  res.end(JSON.stringify(payload));
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    const maxBytes = 1024 * 128;

    req.on("data", (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        reject(new Error("request_body_too_large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => {
      if (chunks.length === 0) {
        resolve({});
        return;
      }

      try {
        const parsed = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        resolve(parsed);
      } catch {
        reject(new Error("invalid_json"));
      }
    });

    req.on("error", reject);
  });
}

function validateSettings(candidate) {
  if (!["mock", "alsa"].includes(candidate.captureMode)) {
    throw new Error("captureMode must be one of: mock, alsa");
  }

  if (!Object.prototype.hasOwnProperty.call(transportSampleRates, candidate.inputTransport)) {
    throw new Error("inputTransport must be one of: alsa_usb, dante");
  }

  if (!transportSampleRates[candidate.inputTransport].includes(candidate.captureRateHz)) {
    throw new Error(
      `captureRateHz=${candidate.captureRateHz} is not supported for transport=${candidate.inputTransport}`
    );
  }

  if (!supportedSampleFormats.includes(candidate.sampleFormat)) {
    throw new Error("sampleFormat must be one of: s16_le, s24_in_32_le");
  }

  if (typeof candidate.alsaDevice !== "string" || candidate.alsaDevice.trim().length === 0) {
    throw new Error("alsaDevice must be a non-empty string");
  }

  if (!Number.isInteger(candidate.channelCount) || candidate.channelCount < 1 || candidate.channelCount > 128) {
    throw new Error("channelCount must be an integer in range 1..128");
  }

  if (
    !Number.isInteger(candidate.testChannelCount) ||
    candidate.testChannelCount < 1 ||
    candidate.testChannelCount > candidate.channelCount
  ) {
    throw new Error("testChannelCount must be an integer in range 1..channelCount");
  }

  if (
    !Number.isInteger(candidate.danteMaxSources) ||
    candidate.danteMaxSources < 1 ||
    candidate.danteMaxSources > 64
  ) {
    throw new Error("danteMaxSources must be an integer in range 1..64");
  }

  if (typeof candidate.mixerProfile !== "string" || candidate.mixerProfile.trim().length === 0) {
    throw new Error("mixerProfile must be a non-empty string");
  }
}

function toEngineEnv(settings) {
  return {
    AUDIO_ENGINE_CAPTURE_MODE: settings.captureMode,
    AUDIO_ENGINE_INPUT_TRANSPORT: settings.inputTransport,
    AUDIO_ENGINE_ALSA_DEVICE: settings.alsaDevice,
    AUDIO_ENGINE_CAPTURE_RATE_HZ: String(settings.captureRateHz),
    AUDIO_ENGINE_SAMPLE_FORMAT: settings.sampleFormat,
    AUDIO_ENGINE_TEST_CHANNEL_COUNT: String(settings.testChannelCount),
    AUDIO_ENGINE_DANTE_MAX_SOURCES: String(settings.danteMaxSources),
  };
}

function saveSettings(settings) {
  fs.writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, "utf8");
}

function loadSettings() {
  try {
    if (!fs.existsSync(settingsPath)) {
      saveSettings(baselineDefaults);
      return { ...baselineDefaults };
    }

    const parsed = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
    const merged = { ...baselineDefaults, ...parsed };
    validateSettings(merged);
    return merged;
  } catch (error) {
    console.error(`failed to load settings from ${settingsPath}: ${error.message}`);
    console.error("falling back to baseline defaults");
    saveSettings(baselineDefaults);
    return { ...baselineDefaults };
  }
}

let currentSettings = loadSettings();

const server = http.createServer(async (req, res) => {
  const parsedUrl = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
  const { method } = req;

  if (method === "GET" && parsedUrl.pathname === "/health") {
    sendJson(res, 200, { status: "ok", service: "control-plane" });
    return;
  }

  if (method === "GET" && parsedUrl.pathname === "/") {
    sendJson(res, 200, {
      service: "control-plane",
      message: "Control plane is running",
      endpoints: [
        "GET /health",
        "GET /settings/audio-input",
        "PUT /settings/audio-input",
        "POST /settings/audio-input/reset",
      ],
    });
    return;
  }

  if (method === "GET" && parsedUrl.pathname === "/settings/audio-input") {
    sendJson(res, 200, {
      settings: currentSettings,
      capabilities: {
        transportSampleRates,
        supportedSampleFormats,
      },
      engineEnv: toEngineEnv(currentSettings),
      notes: [
        "Defaults are WING-oriented but can be customized for other mixers.",
        "audio-engine currently applies these values on startup from env/settings workflow.",
      ],
    });
    return;
  }

  if (method === "PUT" && parsedUrl.pathname === "/settings/audio-input") {
    try {
      const body = await readJsonBody(req);
      const merged = { ...currentSettings, ...body };
      validateSettings(merged);
      currentSettings = merged;
      saveSettings(currentSettings);
      sendJson(res, 200, {
        updated: true,
        settings: currentSettings,
        engineEnv: toEngineEnv(currentSettings),
      });
    } catch (error) {
      const statusCode = error.message === "request_body_too_large" ? 413 : 400;
      sendJson(res, statusCode, {
        error: "invalid_settings_payload",
        details: error.message,
      });
    }
    return;
  }

  if (method === "POST" && parsedUrl.pathname === "/settings/audio-input/reset") {
    currentSettings = { ...baselineDefaults };
    saveSettings(currentSettings);
    sendJson(res, 200, {
      reset: true,
      settings: currentSettings,
      engineEnv: toEngineEnv(currentSettings),
    });
    return;
  }

  sendJson(res, 404, { error: "not_found" });
});

server.listen(port, "0.0.0.0", () => {
  console.log(`control-plane listening on ${port}`);
  console.log(`audio settings file: ${settingsPath}`);
  console.log(`audio defaults file: ${defaultsPath}`);
});
