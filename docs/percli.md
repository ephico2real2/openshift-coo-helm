# percli — Installing the Perses CLI on Linux and macOS

`percli` is the command-line tool of [Perses](https://perses.dev), the dashboard tool in the Cluster Observability Operator (COO). Here it converts Grafana dashboards into Perses dashboards (`percli migrate`).

**Use version 0.54.0.** COO 1.5 builds on Perses v0.54.0 (`rhobs/observability-operator`, branch `release-1.5`, `go.mod`: `github.com/perses/perses v0.54.0`). Keep `percli` at the cluster's Perses version: a newer one can write fields the cluster's Perses does not know.

There are three ways to run it, all measured to give byte-identical output for the same dashboard:

| Way | Needs | Best for |
|---|---|---|
| [1. The install script](#1-the-install-script-linux-and-macos) | `curl`, `tar`, `sha256sum` or `shasum` | a workstation, CI runners |
| [2. By hand](#2-by-hand) | the same | understanding each step, air-gapped copies |
| [3. The container image](#3-the-container-image-nothing-installed) | `podman` or `docker` | nothing installed at all |

## 1. The install script (Linux and macOS)

[`scripts/install-percli.sh`](../scripts/install-percli.sh) picks the archive for the OS and CPU, downloads it with the release's checksums file, **refuses to install if the SHA-256 does not match**, and installs two things:

- `percli`, into `~/.local/bin`;
- the release's 30 plugins, **unpacked**, into `~/.local/share/perses/plugins`. Offline conversion needs them (`--plugin.path`).

> [!WARNING]
> `--plugin.path` must point at **unpacked** plugins. Pointed at the release's `plugins-archive/` (the `.tar.gz` files), `percli migrate` exits 0 and turns **every panel into a placeholder** reading `Migration from Grafana not supported !` (measured with 0.54.0). Always run the check in [Converting a Grafana dashboard](#converting-a-grafana-dashboard).

```bash
scripts/install-percli.sh
# another version or place:
PERCLI_VERSION=0.54.0 PREFIX=/usr/local/bin PLUGINS_DIR=/usr/local/share/perses scripts/install-percli.sh
```

✅ **Expected:**

```text
checksum OK: <sha256 of the archive>
installed /home/<you>/.local/bin/percli
installed /home/<you>/.local/share/perses/plugins (30 plugins, unpacked): pass it to percli migrate --plugin.path
client:
    buildTime: "2026-07-29"
    version: 0.54.0
    commit: 4c719fc19fa21d333797e84c4fe7e3d81c25f4f5
```

Tested on macOS arm64, Linux arm64 and Linux amd64 (UBI 9).

## 2. By hand

Pick the archive for your machine. The SHA-256 values are from the release's `perses_0.54.0_checksums.txt`:

| OS / CPU | Archive | SHA-256 |
|---|---|---|
| Linux x86_64 | `perses_0.54.0_linux_amd64.tar.gz` | `450a387501162fec8e36f0f2628be02ad994fefa989ad1e72a8889ce5eb12a4c` |
| Linux ARM64 | `perses_0.54.0_linux_arm64.tar.gz` | `51e7f66e6e5af4d70d3ab92da6b5ef757368d620ba718e934a4fec225112a353` |
| macOS Apple silicon | `perses_0.54.0_darwin_arm64.tar.gz` | `6afacd914b5cc4aa42838007d894bf1aac9839b00e0b17e14d1ba986802ae01e` |
| macOS Intel | `perses_0.54.0_darwin_amd64.tar.gz` | `afab7440088d6f805b38579b21de5661d531f4c2312ca3b555630eaeecd93f9a` |

**Linux** (here amd64):

```bash
V=0.54.0; A=perses_${V}_linux_amd64.tar.gz
curl -fLO https://github.com/perses/perses/releases/download/v${V}/${A}
curl -fLO https://github.com/perses/perses/releases/download/v${V}/perses_${V}_checksums.txt
grep " ${A}\$" perses_${V}_checksums.txt | sha256sum -c -        # must print: <archive>: OK
tar -xzf ${A} percli plugins-archive
install -m 0755 percli ~/.local/bin/percli
mkdir -p ~/.local/share/perses/plugins
for a in plugins-archive/*.tar.gz; do                            # each plugin into a folder of its own name
  n=$(basename "$a" .tar.gz); mkdir -p ~/.local/share/perses/plugins/$n
  tar -xzf "$a" -C ~/.local/share/perses/plugins/$n
done
percli version
```

**macOS** (here Apple silicon). macOS has `shasum`, not `sha256sum`:

```bash
V=0.54.0; A=perses_${V}_darwin_arm64.tar.gz
curl -fLO https://github.com/perses/perses/releases/download/v${V}/${A}
curl -fLO https://github.com/perses/perses/releases/download/v${V}/perses_${V}_checksums.txt
grep " ${A}\$" perses_${V}_checksums.txt | shasum -a 256 -c -    # must print: <archive>: OK
tar -xzf ${A} percli plugins-archive
install -m 0755 percli ~/.local/bin/percli
mkdir -p ~/.local/share/perses/plugins
for a in plugins-archive/*.tar.gz; do                            # each plugin into a folder of its own name
  n=$(basename "$a" .tar.gz); mkdir -p ~/.local/share/perses/plugins/$n
  tar -xzf "$a" -C ~/.local/share/perses/plugins/$n
done
percli version
```

> [!NOTE]
> Match the archive name exactly (`" ${A}$"`): the checksums file also lists a `.sbom.spdx.json` for each archive, and a looser `grep` makes `-c` report a missing file.

## 3. The container image (nothing installed)

The official image `docker.io/persesdev/perses:v0.54.0` (linux/amd64 and linux/arm64) contains `/bin/percli`. Its plugins ship **packed** in `/etc/perses/plugins-archive`; `/etc/perses/plugins` is **empty** until the Perses **server** in the image starts and unpacks them (about 3 seconds, measured). The image has no shell and no `tar` (distroless, UID 65532), so start it as a server, then run `percli` inside it:

```bash
podman run -d --name percli -v "$PWD:/work:Z" docker.io/persesdev/perses:v0.54.0   # the server unpacks the plugins
sleep 5
podman exec percli /bin/percli migrate -f /work/dashboard.json --format cr --project <namespace> \
  --plugin.path /etc/perses/plugins -o yaml > dashboard.perses.yaml
podman rm -f percli
```

With `docker`, drop `:Z` (an SELinux relabel option podman understands). The mounted folder must be readable by UID 65532. `percli version` alone needs no server: `podman run --rm --entrypoint /bin/percli docker.io/persesdev/perses:v0.54.0 version`.

## Converting a Grafana dashboard

```bash
percli migrate -f dashboard.json --format cr --project <namespace> \
  --plugin.path ~/.local/share/perses/plugins -o yaml > dashboard.perses.yaml

grep -c 'Migration from Grafana not supported' dashboard.perses.yaml   # must print 0
```

- `--format cr` writes a `PersesDashboard` custom resource; `--project` sets its namespace (the Perses project).
- **Offline conversion needs `--plugin.path`.** Without it: `offline migration requires --plugin.path to be specified, or use --online for server-side migration`.
- `--online` converts through a Perses server instead (its `POST /api/migrate`, which on OpenShift takes your token).
- **Offline and COO's server do not convert identically.** For our dashboard, 15 of 16 panels, the variables and the layout came out the same; the **table** differed. Offline `percli` 0.54.0 kept the value mappings (UP/DOWN, colours) and units, and named the value columns `value #1`, `value #2`, … COO's server (Red Hat's build, `rhobs/perses`) named them `Value #A`, `Value #B`, … (Grafana's query letters) and dropped the mappings and units. Check which names the console's table renders before relying on either.
- A Grafana datasource input (`${DS_PROMETHEUS}`) does not convert. It becomes a placeholder list (`grafana`, `migration`, `not`, `supported`). Use `--use-default-datasource`, or `--input DS_PROMETHEUS=<datasource name>`.
- The conversion is best-effort ("Not all Grafana features have direct equivalents in Perses", Red Hat). Review every panel before you rely on it.

## Upgrading

When COO moves to a new Perses version, read the version from `go.mod` on the COO release branch, then rerun the script with `PERCLI_VERSION=<that version>`. The script replaces `plugins/` as a whole.
