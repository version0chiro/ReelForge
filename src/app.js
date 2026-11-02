const status = document.querySelector("#statusMessage p");
const picker = document.querySelector("#fileInput");
const nativeMessage = "ReelForge is now a native macOS app. Run start.command for multi-video analysis and HQ export.";

if (status) status.textContent = nativeMessage;
if (picker) {
  picker.addEventListener("change", () => {
    if (status) status.textContent = nativeMessage;
    picker.value = "";
  });
}
