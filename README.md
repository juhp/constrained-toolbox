# constrained-toolbox

A Haskell rewrite of the fine [toolbox-constrained](https://github.com/swick/toolbox-constrained) tool.

Run a [Toolbx](https://containertoolbx.org/) image in an isolated
podman container. Unlike `toolbox enter`, this does **not** bind-mount
your home directory or integrate with the host by default.
You explicitly choose what the container can access.

## Examples

```
constrained-toolbox TOOLBOX [options] [CMD...]
```

The image is committed (saved) from the named toolbox container using buildah.

### Examples

```bash
# Isolated shell, no host access
constrained-toolbox my-toolbox

# Mount current (project) directory in / and set it as the working directory
constrained-toolbox my-toolbox -p .

# Bind mount a volume
constrained-toolbox my-toolbox -v ~/data:/data

# Use capabilities from config
constrained-toolbox my-toolbox --cap ssh --cap git

# Read-only container filesystem
constrained-toolbox my-toolbox --readonly

# Remove the saved image after exit
constrained-toolbox my-toolbox --delete

# Set environment variables and prepend to PATH
constrained-toolbox my-toolbox -e MY_VAR=hello -P ~/.local/bin

# Run a specific command
constrained-toolbox my-toolbox -- ls /

# Dry run: print the podman command without running it
constrained-toolbox my-toolbox --dryrun
```

### Usage

`$ constrained-toolbox --version`

```
0.1
```

`$ constrained-toolbox --help`

```
constrained-toolbox

Usage: constrained-toolbox [--version] TOOLBOX
                           [-v|--volume HOST:CONTAINER[:opts]]
                           [-e|--env KEY[=VALUE]] [-P|--path DIR]
                           [-i|--init CMD] [--cap NAME] [-p|--project DIR]
                           [--readonly] [--dryrun] [--refresh] [--delete] [CMD]

  Run a toolbox image in an isolated podman container

Available options:
  -h,--help                Show this help text
  --version                Show version
  -v,--volume HOST:CONTAINER[:opts]
                           bind mount (repeatable)
  -e,--env KEY[=VALUE]     set or pass through an environment variable
                           (repeatable)
  -P,--path DIR            prepend a directory to PATH inside the container
                           (repeatable)
  -i,--init CMD            run a bash snippet before entering the container
                           (repeatable)
  --cap NAME               enable a capability from the config file (repeatable)
  -p,--project DIR         mount a project directory (default: cwd) and set as
                           workdir
  --readonly               make the container filesystem read-only
  --dryrun                 print the podman command instead of running it
  --refresh                force re-commit of the toolbox image
  --delete                 remove the committed image after running
```



| Flag | Description |
|------|-------------|
| `-v HOST:CONTAINER[:opts]` | Bind mount (repeatable). `~` and `$ENV_VARS` are expanded. SELinux `:z` label is added automatically unless already specified. |
| `-e KEY[=VALUE]` | Set or pass through an environment variable (repeatable). |
| `-P DIR` | Prepend a directory to `PATH` inside the container (repeatable). |
| `-i CMD` | Run a bash snippet before entering the container (repeatable). |
| `--cap NAME` | Enable a capability from the config file (repeatable). |
| `-p DIR` | Mount a project directory and set it as the container working directory. |
| `--readonly` | Make the container filesystem read-only (tmpfs on `/tmp` and `/run`). |
| `--dryrun` | Print the podman command instead of running it. |
| `--refresh` | Force re-commit of the toolbox image. |
| `--delete` | Remove the committed image after the container exits. |

## Capabilities

Define reusable groups of volumes, environment variables, PATH entries,
and init commands in `~/.config/toolbox-constrained/config.toml`:

```toml
[capabilities.ssh]
volumes = ["~/.ssh:~/.ssh:ro"]

[capabilities.git]
volumes = ["~/.gitconfig:~/.gitconfig:ro"]

[capabilities.wayland]
env = ["WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"]
volumes = ["$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY:$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY:ro"]

[capabilities.rust]
path = ["~/.cargo/bin"]
```

Each capability can define:

- `volumes` — list of bind mount specs
- `env` — list of environment variables to set or pass through
- `path` — list of directories to prepend to `$PATH`
- `init` — a bash snippet to run on container startup

`~` and envvars are expanded in volume and path specs.

## How it works

1. Commits the named toolbox container to an image using `buildah commit`
   (reuses the existing image unless `--refresh` is passed)
2. Runs `podman run` with `--userns=keep-id` so you are your own user, not root
3. Sets up passwordless `sudo` inside the container
4. Bind mounts get SELinux `:z` (shared) labels automatically,
   so multiple containers can safely access the same directories
5. If `--delete` is used, the committed image is removed after exit

## Building

```bash
cabal install
```

## Requirements

- [podman](https://podman.io/) and [buildah](https://buildah.io/)
- An existing toolbox container (created with `toolbox create`)
