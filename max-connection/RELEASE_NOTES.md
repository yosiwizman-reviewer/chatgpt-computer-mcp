## Max Connection 0.1.0 — installer candidate (DRAFT, not published)

Lets ChatGPT (web, phone, iPad) operate a lab computer through Chat On Steroids 2.1.53 (unmodified, pinned) and the computer's own permanent Cloudflare Tunnel under `akior.io`.

### Install on a new computer
1. On a trusted computer: `max-connection/admin/New-ActivationLink.ps1` → a private, single-use link (24 h).
2. On the new computer: open the link, press **Copy activation link**.
3. Run the installer for the platform below and approve the system prompts.
4. The connection helper opens with ChatGPT. In Chat On Steroids → Settings → Setup → step 5 press **Copy** next to each MCP SERVER URL; the helper converts it to `https://mc-<name>.akior.io/...`. In ChatGPT: Plugins → Add → Add custom MCP server, **No authentication**.

| File | Platform |
| --- | --- |
| `Max-Connection-Setup-0.1.0-windows.exe` | Windows 10/11 x64 (ARM64 runs the x64 tunnel under emulation) |
| `Max-Connection-0.1.0-macos.pkg` | macOS, Apple silicon and Intel (unsigned: right-click → Open) |

### Tested
| Test | Windows | macOS |
| --- | --- | --- |
| Package builds in CI | PASS | PASS |
| Installs on a clean machine (MAXCONN-TEST-01, Windows 11 Enterprise eval VM) | PASS | NOT TESTED |
| Activation creates its own tunnel + hostname (`mc-maxconn-t01.akior.io`) | PASS | NOT TESTED |
| Reinstall with a new link keeps the same hostname and tunnel | PASS | NOT TESTED |
| Recovery after a failed first install | PASS | NOT TESTED |
| ChatGPT Core: hostname, write file, read back | PASS | NOT TESTED |
| ChatGPT Desktop: Calculator 5+5=10, screenshot, close | PASS | NOT TESTED |
| Wrong / missing MCP secret, paths outside `/mcp/` → 404 | PASS | NOT TESTED |
| Machine reboot → auto sign-in, tunnel service + app return, same port, ChatGPT works unchanged | PASS | NOT TESTED |
| Tunnel process killed → Windows restarts it | PASS | NOT TESTED |
| Random / reused / expired activation codes refused | PASS (live service) | n/a (server-side) |

Not code-signed or notarized. Chat On Steroids itself does not auto-restart if its process is killed; it returns at the next sign-in.
