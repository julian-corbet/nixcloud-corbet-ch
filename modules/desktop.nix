# modules/desktop.nix
#
# nixcloud's desktop-client concern: the Nextcloud sync GUI (`nextcloud-client`), independent of
# the rclone FUSE mount-serving role modules/core.nix owns.
#
# WHY ITS OWN OPTION, NOT `nixcloud.enable`. `nixcloud.enable` means "this host serves rclone FUSE
# mounts" -- assertions over `nixcloud.accounts`, one systemd unit per mount, the wedged-session
# health monitor and its timer, `/etc/fuse.conf`. None of that is what a desktop session is asking
# for when it wants the Nextcloud sync client, and gating the GUI on it would force a workstation
# to declare itself a mount-serving host (and inherit the health-monitor timer) just to get a
# desktop app -- or force the mount-serving role onto a host with no rclone remotes at all just
# because it also wants this GUI. The two concerns share a NAMESPACE (both are "how this host
# reaches cloud storage") but not a lifecycle, so they get sibling options instead: `cfg.enable`
# for the mount role, `cfg.desktop.enable` for this one, each independently on or off.
#
# WHY ITS OWN FILE, NOT folded into core.nix. core.nix's own header states its reason for bundling
# the health monitor WITH the account schema: the monitor reads `cfg.accounts`, so it lives with
# the data it depends on. This module depends on nothing core.nix defines -- same test, opposite
# answer.
#
# WHY THIS IS THE FIRST NON-NixOS-ONLY SURFACE IN THIS REPO. README's own "Scope" section and
# flake.nix both state modules/core.nix is deliberately NOT portable to system-manager: "running an
# rclone-mount-as-a-server role is inherently a bare-metal-host concept... there's no equivalent
# desktop-session use case this repo is trying to also serve." A Nextcloud sync GUI on a laptop IS
# exactly that desktop-session use case, so the boundary that keeps core.nix NixOS-only does not
# apply here -- see modules/desktop-nixos.nix and modules/desktop-arch.nix for the two backends
# this policy resolves to, the same NixOS/Arch split github:julian-corbet/nixdev uses for every one
# of its own selections.
#
# PLATFORM-NEUTRAL BY DESIGN, mirroring nixdev exactly: this file declares WHAT is wanted and
# resolves the one package name it can ever mean. It sets no `environment.systemPackages` itself --
# that is modules/desktop-nixos.nix's job. On Arch this repo installs nothing directly, matching
# nixdev's own modules/arch.nix reasoning and this estate's standing rule (nixpkgs never shadows a
# package the distro already carries): `nextcloud-client` is a current, official Arch `extra`
# package, so an Arch host is meant to get it from pacman, not from a second, parallel Nix-store
# copy that system-manager's own `environment.systemPackages` would happily also build.
{ config, lib, ... }:
let
  cfg = config.nixcloud.desktop;
in
{
  options.nixcloud.desktop = {
    enable = lib.mkEnableOption "the Nextcloud desktop sync client (nextcloud-client)";

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        `[ "nextcloud-client" ]` when enabled, `[ ]` otherwise -- published as a pacman package
        name for the host's own reconciler to consume, e.g.:

          nixarch.packages.pacman = config.nixcloud.desktop.archPackages;

        This module cannot install it directly on Arch: by this estate's standing rule, a package
        the distro already carries comes from pacman, not from a second Nix-store copy -- the same
        asymmetry nixdev's own modules/arch.nix documents for its whole catalogue.
      '';
    };
  };

  config.nixcloud.desktop.archPackages = lib.optional cfg.enable "nextcloud-client";
}
