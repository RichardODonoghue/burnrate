// Tray spike: proves the Rust side registered tray items and is mutating menu
// text on a timer, which is the pattern the real menu will use every poll.
async function main() {
  const tray = document.getElementById("tray");
  const tick = document.getElementById("tick");
  const core = document.getElementById("core");

  try {
    const info = await window.__TAURI_INTERNALS__.invoke("spike_status");
    tray.textContent = `${info.tray_count} item(s)`;
    core.textContent = info.core;
  } catch (err) {
    tray.textContent = "unavailable";
    core.textContent = String(err);
  }

  setInterval(async () => {
    try {
      const status = await window.__TAURI_INTERNALS__.invoke("spike_status");
      tick.textContent = `${status.tick}`;
    } catch {
      tick.textContent = "—";
    }
  }, 1000);
}

main();
