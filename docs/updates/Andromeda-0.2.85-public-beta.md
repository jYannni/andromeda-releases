<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
## Changed

- Tools groups all 12 actions into compact lists with clearer icons and descriptions.
- Blue primary buttons shimmer in Andromeda’s colors on hover. Reduce Motion uses a static highlight.
- Pause or resume Folder Automation and quit Andromeda from the galaxy menu in the menu bar.
- The all-drives summary now fits free space and the mounted-volume count into a compact row.
- Open archive review for a folder directly from What changed?, Storage Trends, or your plan. External Archives remains available separately.
- The online-only action is now called Cloud Copies.
- A blue download icon appears near Settings when an update is available. Click it to review and install the update.
- The 0.2.85 Public Beta is distributed under the Andromeda Proprietary Software Licence.

## Added

- Keep startup-disk checks running after Quit from Settings › Monitoring. Low-space and rapid-drop alerts can appear as macOS notifications.
- Browse Files in storage alerts, comparisons, and catalog rows to see current files and folders sorted by space used.
- Open Make Room directly below Overview or use the main action after a scan.
- Use Archive and Verify to review a growing folder or choose a project, verify the copy on an external drive, optionally move the original to Trash, and check measured free space in one place.
- Create rules directly in Settings › Organize Rules. Match file names, choose a destination, and optionally limit a rule to one source folder. Matching files appear in the folder preview for you to review before applying the moves.
- Ask Andromeda to remind you when all drives for an archive review or collection export reconnect.
- Review suggested Folder Automation rules based on repeated Organize moves and save them disabled.
- Drop shell scripts into Settings › Automation to add daily or weekly schedules, review the scripts before enabling them, and see each script’s last run result.
- Turn on early space warnings to estimate when your startup disk may reach its free-space limit and open Make Room with a suggested target.
- Use Archive Health in External Archives to link a project to a GitHub repository and check which files are recoverable or still need a copy.

## Fixed

- The hover shimmer follows each primary button’s native shape, including compact buttons.
- Tools headers and hover highlights fill their rows edge to edge.
- The Drive Catalogs header displays the drive icon.
- Compact Storage Map icons have more padding, and tile names and sizes appear immediately beside the pointer.
- Prevented newer Xcode simulator runtime images from being counted twice when the privileged helper is enabled.
- Sidebar rows stay in place when you expand or collapse the sidebar, without overlapping labels or a scrollbar flash.
