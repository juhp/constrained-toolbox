# encapsule

CLI tool to run enclaved (isolated) developer containers that protect your home directory and host from container side effects.
(An "encapsule" is an enclaved container environment, where you control what is shared with the host.)

Originally derived from [toolbox-constrained](https://github.com/swick/toolbox-constrained) tool.

Run a [Toolbx](https://containertoolbx.org/) container or image in an isolated
podman container. Unlike `toolbox enter`, this does *not* bind-mount
your home directory or integrate with the host by default.
You can explicitly choose what to enable and select user-configured "capabilities" the container can access.

```
encapsule TOOLBOX [options] [CMD...]
```

The image is committed (saved) from the named toolbox container using buildah.

## Examples

```bash
# Isolated shell, no host access
$ encapsule my-toolbox

# Mount current (project) directory in / and set it as the working directory
# (also names the container after the project, e.g. encapsule-my-toolbox-myproject)
$ encapsule my-toolbox -p .

# Bind mount a volume
$ encapsule my-toolbox -v ~/data:/data

# Mount a "home" directory (created if it doesn't exist)
$ encapsule my-toolbox --home /tmp/somedir

# Use capabilities from config
$ encapsule my-toolbox --cap ssh --cap git

# Read-only container filesystem
$ encapsule my-toolbox --readonly

# Remove the saved image
$ encapsule my-toolbox --delete

# Set environment variables and prepend to PATH
$ encapsule my-toolbox -e MY_VAR=hello -P ~/.local/bin

# Run a specific command
$ encapsule my-toolbox -- ls /

# Dry run: print the podman command without running it
$ encapsule my-toolbox --dryrun
```

Containers are ephemeral by default: use `--permanent` to create a long lived container to keep around.

### Usage

`$ encapsule --version`

```
0.2.1
```

`$ encapsule --help`

```
encapsule

Usage: encapsule [--version] [TOOLBOX]
                           [-v|--volume HOST:CONTAINER[:opts]]
                           [-e|--env KEY[=VALUE]] [-P|--path DIR]
                           [-i|--init CMD] [--cap NAME] [--home DIR]
                           [-p|--project DIR]
                           [--caps | --remove | --delete-image | --stop]
                           [--persistent] [--readonly] [--no-network] [--unique]
                           [--dryrun] [--refresh] [CMD]

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
  --home DIR               Mount a directory as a writable home (created if
                           missing)
  -p,--project DIR         Mount a project directory and set as workdir
  --caps                   List available capabilities from the config file
  --remove                 Remove the container
  --delete-image           Remove the image
  --stop                   Stop the container
  --persistent             Keep the container after exiting
  --readonly               Make the container filesystem read-only
  --no-network             Disable network access
  --unique                 Run a new container even if one is already running
  --dryrun                 Print the podman command instead of running it
  --refresh                Force re-commit of the toolbox image
```

## Capabilities

Define reusable groups of volumes, environment variables, PATH entries,
and init commands in `~/.config/encapsule/config.toml`:

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
5. When `-p/--project DIR` is used (and `--name` isn't), the container name
   includes the project directory's name (e.g. `encapsule-my-toolbox-myproject`),
   so you can run the same toolbox against different projects at the same time
   in separate containers

## Installation

A copr repo is available for Fedora and Epel 10:

<https://copr.fedorainfracloud.org/coprs/petersen/encapsule/>

## Building from source

```bash
cabal install
```

or `stack install`.

## Requirements

- [podman](https://podman.io/) and [buildah](https://buildah.io/)
- An existing toolbox container (created with `toolbox create`)

## Related projects

I already mentioned [toolbox-constrained](https://github.com/swick/toolbox-constrained) which this project is derived from.

There is also similarly [schupfn](https://github.com/whot/schupfn/) which uses Qemu to run a toolbox container image in a VM with a direct private ssh connection.

For stronger isolation, specially network, consider using [OpenShell](https://github.com/NVIDIA/OpenShell/).
