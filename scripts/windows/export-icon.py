"""Export the approved Flutter squirrel mask to Windows ICO; no artwork changes."""
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[2]
source = Image.open(root / "apps/exvpn/assets/images/squirrel-mask.png").convert("RGB")
# Exact ColorFilter matrix used by ExVPN's Flutter wordmark.
alpha = source.getchannel("R").point(lambda red: max(0, min(255, round(red * 1.04 - 5))))
icon = Image.new("RGBA", source.size, (255, 189, 81, 0))
icon.putalpha(alpha)
icon.save(root / "apps/exvpn/windows/runner/resources/app_icon.ico", format="ICO",
          sizes=[(size, size) for size in (16, 20, 24, 32, 40, 48, 64, 128, 256)])
print("Exported existing ExVPN squirrel mask to multi-resolution ICO.")
