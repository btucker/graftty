# Run a headless host with Docker

Use `graftty-runner` to run the Linux headless host on Linux or Docker Desktop
with the WSL2 backend on Windows. The image includes `graftty-host`, the
`graftty` CLI, the pinned Graftty-patched zmx, Bash, Git, curl, and an SSH client.
Install project toolchains and agent CLIs separately in a derived image.

Container replacement ends running terminals and agents. A persistent home
volume retains repositories, host identity, pairing, and configuration.

## Start the runner

After the first image release, run this command on the Docker host:

```sh
docker run --detach --name graftty-runner --hostname graftty-runner \
	--restart unless-stopped \
	--mount type=volume,source=graftty-runner-home,target=/home/runner \
	--publish 127.0.0.1:8800:8800 --publish 127.0.0.1:8801:8801 \
	ghcr.io/btucker/graftty-runner:latest
```

For repeatable deployments, replace `latest` with a published version tag or
image digest. Stable releases publish a version tag and `latest`. Prereleases
publish only their full version tag. Build metadata uses `_` in place of `+`,
so release `v1.2.3+build.4` has image tag `1.2.3_build.4`.
Both AMD64 and ARM64 are supported.

For a Mac on another machine, replace `127.0.0.1` with the Docker host's LAN or
VPN address. Allow that Mac to reach ports 8800 and 8801. Verify Windows firewall
and Docker port forwarding from the Mac. Publishing to loopback allows only
connections from the Docker host.

Check readiness:

```sh
docker inspect --format '{{.State.Health.Status}}' graftty-runner
docker exec graftty-runner graftty-host status --json
```

Wait for `healthy` and `"running":true`.

## Pair the Mac

1. In the Mac's **Remote Hosts** menu, choose **Add Remote Mac…**.
2. Enter `http://DOCKER_HOST:8800` in **URL**.
3. Choose **Direct SSH**, enter the Docker host's address, and use port `8801`.
4. Start pairing, then inspect the pending verification code on the runner:

   ```sh
   docker exec graftty-runner graftty-host pair pending
   ```

5. Compare the code with the Mac's code. Confirm the matching code locally:

   ```sh
   docker exec graftty-runner graftty-host pair confirm 123456
   ```

6. Complete verification on the Mac.

Use **Add Remote Mac…** for this manually installed Linux host. **Set Up Linux
Host…** expects system SSH and a systemd user service. Container startup uses
the foreground host process and tini instead of systemd.

## Add repositories and agent tools

Clone and register a repository inside the persistent home volume:

```sh
docker exec -it graftty-runner bash
git clone https://github.com/YOUR_ORG/YOUR_REPO.git /home/runner/projects/app
graftty-host project add /home/runner/projects/app --json
```

Authenticate Git and agent providers inside the runner. Host credentials are
not copied into the image. The home volume contains those local credentials
after sign-in, so retain it as private application data.

The runner uses UID and GID `10001`. For bind mounts, give that user access to
the mounted files. On WSL2, keep repositories in the Linux filesystem or use
the named home volume to avoid Windows filesystem overhead.

To include a project's compilers and agent executables, build a derived image:

```dockerfile
FROM ghcr.io/btucker/graftty-runner:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
	&& rm -rf /var/lib/apt/lists/*
# Install agent executables here using their official Linux installers.
USER runner
```

Install executables under `/usr/local` or another image directory outside
`/home/runner`. An existing home volume hides files installed there by a newer
image. Keep provider authentication out of Docker build layers.

## Update the runner

Finish or save running work before replacing the container. Pull the selected
image tag, stop and remove the container, then repeat the startup command with
the same home volume. Do not remove the volume.

Use image replacement for updates. The Mac's **Update Host…** flow manages a
systemd installation and cannot update this container.

Docker does not add the unfinished outbound enrollment or rendezvous
connection. This deployment requires a reachable direct route from the Mac.
Container restart, Docker engine shutdown, WSL termination, and Windows reboot
end live processes. Docker's restart policy starts a new host process afterward.

## Build and validate an image locally

Build an archive on Linux with `scripts/linux/package.sh`, or download the
architecture-matched archive and checksum from a trusted Graftty release.
Verify the checksum before building:

```sh
cd /path/to/downloads
sha256sum -c graftty-linux-VERSION-aarch64.tar.gz.sha256
cd /path/to/graftty
scripts/linux/runner/build.sh /path/to/downloads/graftty-linux-VERSION-aarch64.tar.gz
scripts/linux/runner/smoke-test.sh graftty-runner:local
```

Use `x86_64` in the filename for AMD64. The build script selects the matching
Docker platform and creates a temporary build context containing only the
archive and Dockerfile. The smoke test checks non-root startup, both listeners,
terminal input and output, graceful shutdown, and persistence after replacement.

Release automation publishes `ghcr.io/btucker/graftty-runner` after the Mac
release and Linux archive checks pass. It uses the workflow's `GITHUB_TOKEN`
with `packages: write`; no Docker Hub credential is needed.

To publish an image for an existing release, run **Publish runner from an
existing release** in GitHub Actions on `main`. Enter the published release tag,
such as `v0.8.0`. This workflow downloads and verifies that release's Linux
archives, tests both images, and publishes their manifest without a Mac release.
Publishing a stable version also updates `latest`, so select the newest stable
release when publishing manually.

After the first publication,
[make the GitHub package public](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)
to allow anonymous pulls.
