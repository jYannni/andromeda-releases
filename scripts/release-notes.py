"""Write the bundled history and Sparkle notes for a distribution build."""

import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHANNELS = ("private-beta", "public-beta", "public-release")


def version_key(version):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}", version):
        raise ValueError(f"Invalid release version: {version}")
    return tuple(map(int, version.split(".")))


def rollup(target, entries):
    sections = {}
    for entry in entries:
        for section in entry["sections"]:
            items = sections.setdefault(section["title"], {})
            items.update(dict.fromkeys(section["items"]))
    return {
        **target,
        "sections": [{"title": title, "items": list(items)} for title, items in sections.items()],
    }


def build_history(source, promotions, channel, version):
    entries = {entry["version"]: entry for entry in source}
    if len(entries) != len(source):
        raise ValueError("Each version needs exactly one source history entry")
    versions = sorted(entries, key=version_key)
    if version not in entries:
        raise ValueError(f"Add source release notes for {version}")
    if channel == "private-beta":
        return [entries[v] for v in reversed(versions) if version_key(v) <= version_key(version)]

    releases = promotions["public-release"]
    betas = promotions["public-beta"]
    for values in (releases, betas):
        if values != sorted(set(values), key=version_key) or any(v not in entries for v in values):
            raise ValueError("Promotion versions must be unique, increasing, and have source notes")
    if not releases or (betas and version_key(betas[0]) <= version_key(releases[0])):
        raise ValueError("Record a public release baseline before the first public beta")
    if betas and any(v not in betas for v in releases if version_key(v) >= version_key(betas[0])):
        raise ValueError("Promote later public releases through public beta")
    if version not in promotions[channel]:
        raise ValueError(f"Record the {version} promotion to {channel} before packaging")

    beta_notes = {}
    stable_notes = {}
    private_changes = []
    beta_changes = []
    for current in versions:
        private_changes.append(entries[current])
        if current in betas:
            beta_notes[current] = rollup(entries[current], private_changes)
            beta_changes.append(beta_notes[current])
            private_changes.clear()
        if current in releases:
            stable_notes[current] = (
                rollup(entries[current], beta_changes or private_changes)
                if stable_notes else entries[current]
            )
            beta_changes.clear()
            private_changes.clear()

    history = stable_notes if channel == "public-release" else {**stable_notes, **beta_notes}
    return [history[v] for v in reversed(versions) if v in history and version_key(v) <= version_key(version)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("channel", choices=CHANNELS)
    parser.add_argument("version")
    parser.add_argument("history", type=Path)
    parser.add_argument("markdown", type=Path)
    args = parser.parse_args()
    try:
        source = json.loads((ROOT / "Sources/AndromedaAppModel/Releases.json").read_text(encoding="utf-8"))
        promotions = json.loads((ROOT / "Resources/App/ReleasePromotions.json").read_text(encoding="utf-8"))
        history = build_history(source, promotions, args.channel, args.version)
        markdown = []
        for section in history[0]["sections"]:
            markdown.extend((f"## {section['title']}", ""))
            markdown.extend(f"- {item}" for item in section["items"])
            markdown.append("")
        args.history.write_text(json.dumps(history, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        args.markdown.write_text("\n".join(markdown), encoding="utf-8")
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Cannot prepare release notes: {error}\n")


if __name__ == "__main__":
    main()
