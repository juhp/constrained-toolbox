# encapsule

CLI tool to run developer containers, isolating your home directory and host from container side effects:
"encapsules" a project and/or temp home dir together with select "capabilities".

Originally derived from [toolbox-constrained](https://github.com/swick/toolbox-constrained) tool.

Run a ([toolbox](https://containertoolbx.org/)) container or image as
an isolated podman container. Unlike with `toolbox enter`, this does *not*
bind-mount your home directory or integrate with the host by default.
You can explicitly choose what dir(s) to mount or features to enable,
selecting user-configured "capabilities" that the encapsule container can access.

```
encapsule TOOLBOX [options] [CMD...]
```

if TOOLBOX is a container it will be committed (saved) to an "encapsule" container image from the named toolbox container using buildah.

## Examples

```bash
# Isolated shell without host fs access
$ encapsule my-toolbox

# Mount current (project) directory in / and set it as the working directory
# (also names the container after the project, e.g. encapsule-my-toolbox-myproject)
$ encapsule my-toolbox -p .

# Bind mount a volume
$ encapsule my-toolbox -v ~/data:/data

# Mount a temp "home" directory (created if it doesn't exist)
$ encapsule my-toolbox --home /tmp/somedir

# Use capabilities from config
$ encapsule my-toolbox --cap ssh --cap git

# Read-only container filesystem
$ encapsule my-toolbox --readonly

# Remove the saved image
$ encapsule my-toolbox --delete-image

# Set environment variables and prepend to PATH
$ encapsule my-toolbox -e MY_VAR=hello -P ~/.local/bin

# Run a specific command
$ encapsule my-toolbox -- ls /

# Dry run: print the full podman command without running it
$ encapsule my-toolbox --dryrun

# run directly from an image
$ encapsule fedora:44 --home tmphome
```

Encapsule containers are ephemeral by default: use `--keep` to leave the encapsule container around for reuse. Note the saved image will be reused next time unless using `--refresh`.

### Usage

`$ encapsule --version`

```
0.3
```

`$ encapsule --help`

```
encapsule

Usage: encapsule [--version] [TOOLBOX] [-v|--volume HOST:CONTAINER[:opts]]
                 [-e|--env KEY[=VALUE]] [-P|--path DIR] [-i|--init CMD]
                 [--cap NAME] [--home DIR] [-p|--project DIR] [-n|--name NAME]
                 [--caps | --list | --remove | --delete-image | --stop] [--keep]
                 [--readonly] [--no-network] [--no-sudo] [--unique]
                 [--podman-opt OPTION] [--debug] [--dryrun] [--refresh] [CMD]

  Run a toolbox image in an isolated podman container

Available options:
  -h,--help                Show this help text
  --version                Show version
  -v,--volume HOST:CONTAINER[:opts]
                           Bind mounts (default to selinux :z)
  -e,--env KEY[=VALUE]     Set or pass through an environment variable
  -P,--path DIR            Prepend a directory to PATH inside the container
  -i,--init CMD            A bash snippet run when creating the encapsule
                           container
  --cap NAME               Enable a capability from the config file
  --home DIR               Mount a directory as a writable home (created if
                           missing)
  -p,--project DIR         Mount a project directory and set as workdir
  -n,--name NAME           Container name (for creating or actions)
  --caps                   List available capabilities from the config file
  --list                   List encapsule images and containers
  --remove                 Remove encapsule container
  --delete-image           Remove encapsule image
  --stop                   Stop encapsule container
  --keep                   Keep the encapsule container after exiting
  --readonly               Make the encapsule container filesystem read-only
  --no-network             Disable network access
  --no-sudo                Skip passwordless sudo setup
  --unique                 Run a new encapsule container even if one is already
                           running
  --podman-opt OPTION      Pass an option directly to podman
  --debug                  Show debug output
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
- `init` — a bash snippet to run on encapsule container creation
- `security_opts` — list of `--security-opt` values passed to podman

`~` and envvars are expanded in volume and path specs.
If the host and container paths are the same, you can use the shorthand
`PATH[:opts]` instead of `PATH:PATH[:opts]`.

## How it works

1. Commits the named toolbox container to an encapsule image using `buildah commit`
   (reuses the existing image unless `--refresh` is passed)
2. Runs `podman run` with `--userns=keep-id` so you are your own user, not root
3. Tries to install runuser (util-linux) and sudo if they are missing with dnf or apt-get.
4. Sets up passwordless `sudo` inside the encapsule container (unless `--no-sudo`)
5. Bind mounts get SELinux `:z` (shared) labels automatically,
   so multiple containers can safely access the same directories
6. When `-p/--project DIR` is used (and `--name` isn't), the container name
   includes the project directory's name (e.g. `encapsule-mytoolbox-myproject`),
   so you can run the same toolbox against different projects at the same time
   in separate encapsule containers

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
- An existing (toolbox) container (created with `toolbox create`) or image.
- Alternatively some non-toolbox other container/images may also work.

## Related projects

I already mentioned [toolbox-constrained](https://github.com/swick/toolbox-constrained) from which the initial code was derived.

There is also similarly [schupfn](https://github.com/whot/schupfn/) which uses QEMU to run a toolbox container image in a VM with a direct private ssh connection.

For stronger sandboxing and isolation, specially network, consider using [OpenShell](https://github.com/NVIDIA/OpenShell/).

## Contribute

`encapsule` is at <https://github.com/juhp/encapsule> and distributed
under the Apache-2.0 license.
