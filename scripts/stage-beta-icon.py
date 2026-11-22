"""Make a beta Icon Composer document from the release galaxy artwork."""

import json
import shutil
import sys
from pathlib import Path


def group(asset, name, glass):
    return {
        "layers": [{"image-name": asset, "name": name, "glass": glass}],
        "translucency": {"enabled": False, "value": 0},
    }


resources, output, channel = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
shutil.copytree(resources / "AppIcon.icon", output)
icon = output / "icon.json"
document = json.loads(icon.read_text())
label = channel.split("-", 1)[0]
for asset, name in ((f"{label}-badge.svg", f"{label.title()} badge"), ("beta-badge.svg", "Beta badge")):
    shutil.copyfile(resources / "BetaIcon" / asset, output / "Assets" / asset)
    document["groups"].insert(0, group(asset, name, True))
if channel == "private-beta":
    grid = "private-grid.svg"
    shutil.copyfile(resources / "BetaIcon" / grid, output / "Assets" / grid)
    document["groups"].append(group(grid, "Tilted grid", False))
    document["fill"]["linear-gradient"] = [
        "display-p3:0.49,0.28,0.82,1",
        "display-p3:0.21,0.12,0.44,1",
    ]
icon.write_text(json.dumps(document, indent=2) + "\n")
