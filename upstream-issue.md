**Title:** `rclone.conf` is written world-readable (0644) with master keys and private key in plaintext

### Summary

`write_rclone_config()` writes `<config_dir>/rclone.conf` with `tokio::fs::write`, which does not set a file mode. Under the default `umask 022` the file is created **0644 — readable by every local user**. The file contains the account's `master_keys` and `private_key` in plaintext, plus an `api_key` protected only by `rclone obscure`.

On a multi-user machine, any other local account can read this file and decrypt the user's entire Drive, which undercuts the zero-knowledge guarantee.

The same repository already solves this correctly for its other credential file, so this looks like an oversight rather than a deliberate choice.

### Affected code

`filen-rclone-wrapper/src/rclone_installation.rs` → `write_rclone_config()`

```rust
let rclone_config_content = format!(
    "[filen]\ntype = filen\npassword = {}\nemail = {}\nmaster_keys = {}\napi_key = {}\npublic_key = {}\nprivate_key = {}\nauth_version = {}\nbase_folder_uuid = {}\n",
    obscure_password_for_rclone(rclone_binary_path, "INTERNAL").await?,
    client.email(),
    client_sdk_config.master_keys.join("|"),     // plaintext
    obscure_password_for_rclone(rclone_binary_path, &client_sdk_config.api_key).await?,
    client_sdk_config.public_key,
    client_sdk_config.private_key,               // plaintext
    client_sdk_config.auth_version as u8,
    client_sdk_config.base_folder_uuid
);

// `fs` here is `tokio::fs` (see the `use tokio::{fs, ...}` at the top of the file);
// like `std::fs::write` it creates the file with 0666 & !umask and sets no explicit mode.
fs::write(&rclone_config_path, rclone_config_content)
    .await
    .context("Failed to write Rclone config file")?;
```

Notes on the field protection:

- `master_keys` and `private_key` are written **raw**.
- `api_key` is passed through `rclone obscure`, which is obfuscation, not encryption — it is reversible by design with `rclone reveal`:
  ```console
  $ rclone obscure "hunter2-not-a-real-secret"
  c1A6MsTAsxoXoOZm5akT6znITXieT2tjZwTESzSLZIjijJBxOwRQq4s

  $ rclone reveal "c1A6MsTAsxoXoOZm5akT6znITXieT2tjZwTESzSLZIjijJBxOwRQq4s"
  hunter2-not-a-real-secret
  ```
  (rclone's own docs note that `obscure` is not encryption and offers no real protection for a config an attacker can read.)
- The containing directory does not compensate: `create_dir_all` leaves `<config_dir>` at 0755 as well.

### The inconsistency

`filen-cli/src/auth.rs` writes the auth config (`filen-cli-auth-config.txt`) through a hardened helper, complete with a comment explaining exactly this risk and three unit tests asserting 0600:

```rust
/// Write `contents` to `path`, creating or truncating it with owner-only permissions
/// (mode `0o600` on Unix). The auth config holds the master keys, private key and API key,
/// so it must never be left group- or world-readable for other users on the machine.
fn write_private_file(path: &Path, contents: &str) -> std::io::Result<()> { ... }
```

`write_rclone_config()` stores the same class of secrets but does not use it.

That helper arrived in `1cac088` — *"fix(cli): write the exported auth config file with 0o600 permissions … instead of relying on the process umask"* (2026-07-13). That commit touched only `filen-cli/src/auth.rs`. `write_rclone_config()` lives in a separate crate (`filen-rclone-wrapper`, added 2025-12-21) and was not covered by it, so the same reasoning does not currently apply there.

Both files can also end up in the same config tree, which makes the difference in handling easy to overlook.

### Steps to reproduce

Observed with CLI `0.2.7` on Linux (`umask 022`), and the same code path is present on `main` at `a12f2be`.

1. Authenticate the CLI (`filen stat /`, choose to stay signed in).
2. Run any command that uses the managed rclone, e.g. `filen rclone lsjson filen:/`.
3. Inspect the generated config:

```console
$ stat -c '%n mode=%a' ~/.config/filen-cli/rclone/rclone.conf
/home/user/.config/filen-cli/rclone/rclone.conf mode=644

$ sed -E 's/=.*/= <REDACTED>/' ~/.config/filen-cli/rclone/rclone.conf
[filen]
type = <REDACTED>
password = <REDACTED>
email = <REDACTED>
master_keys = <REDACTED>
api_key = <REDACTED>
public_key = <REDACTED>
private_key = <REDACTED>
auth_version = <REDACTED>
base_folder_uuid = <REDACTED>
```

Whether another local user can then *reach* it depends on the home directory, which this project does not control (see the correction comment on the issue): on distributions with 0700 homes (Arch, Fedora, Ubuntu >= 21.04) and on macOS, traversal is blocked; on Debian-style 0755 homes, shared/NFS homes, CI runners and multi-user servers, it is directly readable.

### Standalone proof of the mode difference

This needs no account and no credentials — it just contrasts the two write paths used in the repo:

```rust
use std::os::unix::fs::PermissionsExt;

fn main() {
    let dir = std::env::temp_dir().join("filen-perm-demo");
    std::fs::create_dir_all(&dir).unwrap();

    // Path A: equivalent of what write_rclone_config() uses today.
    // (tokio::fs::write defers to the same open(2) flags; neither sets a mode.)
    let a = dir.join("a-fs-write.conf");
    std::fs::write(&a, "master_keys = <secret>\n").unwrap();

    // Path B: what auth.rs::write_private_file() uses.
    let b = dir.join("b-private-file.conf");
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut o = std::fs::OpenOptions::new();
        o.write(true).create(true).truncate(true).mode(0o600);
        let mut f = o.open(&b).unwrap();
        f.set_permissions(std::fs::Permissions::from_mode(0o600)).unwrap();
        f.write_all(b"master_keys = <secret>\n").unwrap();
    }

    for (label, p) in [("fs::write          (rclone.conf path)", &a),
                       ("write_private_file (auth config path)", &b)] {
        let m = std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        println!("{label} -> {:04o}", m);
    }
}
```

```console
$ rustc -O -o perm_demo perm_demo.rs && ./perm_demo
fs::write          (rclone.conf path) -> 0644
write_private_file (auth config path) -> 0600
```

### Impact

- **Requires:** another local account (or any process running as a different user) on the same machine. Not remotely exploitable.
- **Grants:** full read of `master_keys` + `private_key` → the ability to decrypt all of the victim's Drive contents and metadata offline, plus a reversible `api_key` for authenticated API access.
- Particularly relevant on shared workstations, multi-user servers, and CI hosts, which are also where a headless CLI is most likely to be used.

### Suggested fix

Reuse the existing hardening for this file too — create it 0600 and tighten it explicitly, since `create + truncate` preserves the mode of a pre-existing file (so machines that already have a 0644 config stay vulnerable until it is re-tightened):

```rust
#[cfg(unix)]
{
    use std::os::unix::fs::OpenOptionsExt;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true).mode(0o600);
    let mut file = options.open(&rclone_config_path)?;
    use std::os::unix::fs::PermissionsExt;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    file.write_all(rclone_config_content.as_bytes())?;
}
```

Worth considering alongside it:

1. Create `<config_dir>` itself as 0700 (`rclone_installation.rs` `create_dir_all`). This also covers the sibling `filen-sdk-rs-cache/` and `logs/` directories.
2. Re-tighten on every write, so existing installations are repaired on upgrade rather than only new ones being safe.
3. A unit test mirroring `write_private_file_creates_owner_only` / `write_private_file_tightens_existing_lax_file`.
4. On Windows no Unix mode applies and the file inherits profile ACLs; a comment noting that would avoid confusion, no code needed.
5. Longer term: avoid materialising `master_keys` / `private_key` on disk at all if rclone can be fed the config over stdin or a `--config /dev/fd/N` handle.
6. `filen logout` should delete `rclone.conf`. Today it clears the keyring entries but leaves this file. Tested on 0.2.7: after `logout`, `rclone.conf` is still on disk with `master_keys`, `api_key` and `private_key`, and the managed rclone (`rclone-v1.74.2-linux-amd64 --config <config_dir>/rclone/rclone.conf lsf filen:/`) still lists the drive. Signing out therefore does not revoke local access; users have to delete the file by hand.

### Workaround for users

```bash
chmod 600 ~/.config/filen-cli/rclone/rclone.conf
```

This survives subsequent CLI runs (the rewrite preserves the tightened mode), but it has to be applied manually and re-checked after a fresh install or a new config dir.

### Environment

- Filen CLI 0.2.7 (`filen-cli-releases`), Linux x86_64
- Source verified against `filen-rs` `main` @ `a12f2be`
- `umask 022` (distribution default)
