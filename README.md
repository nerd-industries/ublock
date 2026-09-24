# ublock

Install **uBlock** on every browser a Windows PC actually has (Edge, Chrome,
Firefox) in one go, through browser policy.

Served via Cloudflare Pages at **https://ublock.nerdyneighbor.net** so the latest
committed version always runs.

## Run it (elevated Windows PowerShell)

```powershell
irm ublock.nerdyneighbor.net | iex
```

Options (set before the irm line):

```powershell
$env:NN_EDGE = 'lite'        # Edge gets uBlock Origin Lite instead of full uBlock Origin
irm ublock.nerdyneighbor.net | iex

$env:NN_UBLOCK = 'revert'    # remove every policy this script set
irm ublock.nerdyneighbor.net | iex
```

Also available in the menu: `irm toolkit.nerdyneighbor.net | iex`.

## What it does

1. **Detects installed browsers.** A browser counts only if its program file exists **and**
   Windows has it registered (Uninstall entry, or the Store package for Firefox).
   Leftover profile folders don't count. Per-user Chrome installs in AppData are included.
2. **Installs the right uBlock on each one** using `ExtensionSettings` with
   `normal_installed`. It installs automatically, and the user can disable it but not remove it:

   | Browser | Extension | ID |
   |---|---|---|
   | Edge | uBlock Origin (default) or uBlock Origin Lite (`NN_EDGE=lite`) | `odfafepnkmbhccpbejgmiehpchacaeak` / `cimighlppcgcoapaliogpjjdehbnofhn` |
   | Chrome | uBlock Origin Lite | `ddkjiahejlhfcafbddmgiahcphecmpfh` |
   | Firefox | uBlock Origin | `uBlock0@raymondhill.net` |

   It merges into any existing `ExtensionSettings` JSON instead of overwriting it.
3. **Sets uBlock Origin Lite to "Complete" filtering** through its managed-storage policy
   (`3rdparty\extensions\<id>\policy\defaultFiltering = complete`).
4. **Private browsing:**
   - Firefox: enabled by policy (`private_browsing: true`, Firefox 136+).
   - Chrome/Edge: **no policy can do this.** When a tech runs the script interactively, it
     restarts the browser as the logged-on user and opens the extension's page.
     Turn on **Allow in Incognito** / **Allow in InPrivate** there.
5. **Edge + full uBO:** sets `ExtensionManifestV2Availability = 2` (only if it isn't already set)
   so the Manifest V2 extension keeps running.
6. Asks before closing browsers (it never closes them when run from the RMM). Logs to
   `C:\ProgramData\NerdyNeighbor\ublock.log`.

## Caveats

- **Full uBlock Origin on Edge has an expiry date.** Microsoft is disabling Manifest V2
  extensions for consumers by the end of 2026. After that, re-run with `NN_EDGE=lite`, or flip
  `$EdgeDefault` in the script to `'lite'` and push.
- Browsers show "Managed by your organization" because policies are in use.
- The Incognito/InPrivate toggle only covers the **Default** browser profile. Extra profiles
  need the toggle flipped by hand.
- Run from SuperOps (SYSTEM), everything except the Chrome/Edge incognito toggle still
  applies. Extensions install the next time each browser is fully closed and reopened.
- Revert removes the policies but leaves uBlock installed. The user can then remove it normally.
