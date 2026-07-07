# constrained-toolbox

A Haskell rewrite of the fine [toolbox-constrained](https://github.com/swick/toolbox-constrained) tool.

Run a [Toolbx](https://containertoolbx.org/) image in an isolated
podman container. Unlike `toolbox enter`, this does *not* bind-mount
your home directory or integrate with the host by default.
You explicitly choose what the container can access.

```
constrained-toolbox TOOLBOX [options] [CMD...]
```

The image is committed (saved) from the named toolbox container using buildah.

## Examples

```bash
# Isolated shell, no host access
$ constrained-toolbox my-toolbox

# Mount current (project) directory in / and set it as the working directory
$ constrained-toolbox my-toolbox -p .

# Bind mount a volume
$ constrained-toolbox my-toolbox -v ~/data:/data

# Use capabilities from config
$ constrained-toolbox my-toolbox --cap ssh --cap git

# Read-only container filesystem
$ constrained-toolbox my-toolbox --readonly

# Remove the saved image after exit
$ constrained-toolbox my-toolbox --delete

# Set environment variables and prepend to PATH
$ constrained-toolbox my-toolbox -e MY_VAR=hello -P ~/.local/bin

# Run a specific command
$ constrained-toolbox my-toolbox -- ls /

# Dry run: print the podman command without running it
$ constrained-toolbox my-toolbox --dryrun
```

### Usage

`$ constrained-toolbox --version`

```
0.1
```

`$ constrained-toolbox --help`

```
constrained-toolbox

Usage: constrained-toolbox [--version] [TOOLBOX]
                           [-v|--volume HOST:CONTAINER[:opts]]
                           [-e|--env KEY[=VALUE]] [-P|--path DIR]
                           [-i|--init CMD] [--cap NAME] [-p|--project DIR]
                           [--caps] [--readonly] [--dryrun] [--refresh]
                           [--delete] [CMD]

  Run a toolbox image in an isolated podman container

Available options:
  -h,--help                Show this help text
  --version                Show version
  -v,--volume HOST:CONTAINER[:opts]
                           Bind mounts (default to selinux :z)
  -e,--env KEY[=VALUE]     Set or pass through an environment variables
  -P,--path DIR            Prepend a directory to PATH inside the container
  -i,--init CMD            Run a bash snippet before entering the container
  --cap NAME               Enable a capability from the config file
  -p,--project DIR         Mount a project directory and set as workdir
  --caps                   List available capabilities from the config file
  --readonly               Make the container filesystem read-only
  --dryrun                 Print the podman command instead of running it
  --refresh                Force re-commit of the toolbox image
  --delete                 Remove the committed image after running
```

## Capabilities

Define reusable groups of volumes, environment variables, PATH entries,
and init commands in `~/.config/constrained-toolbox/config.toml`:

```toml
[capabilities.ssh]
volumes = ["~/.ssh:~/.ssh:ro"]

[capabilities.git]
volumes = ["~/.gitconfig:ro"]

[capabilities.wayland]
env = ["WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"]
volumes = ["$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"]
security_opts = ["label=disable"]

[capabilities.rust]
path = ["~/.cargo/bin"]
```

Each capability can define:

- `volumes` — list of bind mount specs
- `env` — list of environment variables to set or pass through
- `path` — list of directories to prepend to `$PATH`
- `init` — a bash snippet to run on container startup
- `security_opts` — list of `--security-opt` values passed to podman

`~` and envvars are expanded in volume and path specs.
If the host and container paths are the same, you can use the shorthand
`PATH[:opts]` instead of `PATH:PATH[:opts]`.

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
