# modules/desktop-nixos.nix
#
# NixOS backend for the desktop-client concern (modules/desktop.nix) -- resolves
# `nixcloud.desktop.enable` into `environment.systemPackages`, the same install mechanism
# `nixcloud.enable` already uses for `rclone` in modules/core.nix. Unlike core.nix's own mount
# mechanism this has no systemd units, no accounts, nothing else host-specific: one option, one
# package, gated.
{ config, lib, pkgs, ... }:
{
  imports = [ ./desktop.nix ];

  config.environment.systemPackages =
    lib.mkIf config.nixcloud.desktop.enable [ pkgs.nextcloud-client ];
}
