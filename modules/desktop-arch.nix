# modules/desktop-arch.nix
#
# Arch / system-manager backend for the desktop-client concern (modules/desktop.nix). Installs
# nothing itself, same reasoning as github:julian-corbet/nixdev's own modules/arch.nix: this
# estate's standing rule is that a package the distro already carries comes from pacman, never a
# second Nix-store copy, so there is no installer here to call. `nixcloud.desktop.archPackages` is
# published for the host's own reconciler:
#
#   nixarch.packages.pacman = config.nixcloud.desktop.archPackages;
#
# Importing this module is therefore equivalent to importing modules/desktop.nix directly; it
# exists so that composing it reads as a deliberate choice in a host's imports rather than an
# accident of which file someone happened to pick -- again, exactly nixdev's own stated reason for
# keeping its otherwise-empty arch.nix.
{ ... }:
{
  imports = [ ./desktop.nix ];
}
