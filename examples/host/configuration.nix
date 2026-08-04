# examples/host/configuration.nix
#
# A toy host used only by `flake.nix`'s own `checks` -- not meant to be
# imported by a real system. Two accounts on purpose: one plain, one
# `fragile` with an overridden cache mode, so the checks can prove the
# two actually diverge (backoff timing, rendered flags) rather than just
# "the module evaluates".
{
  nixcloud = {
    enable = true;

    mountRoot = "/mnt/clouds";
    configPath = "/run/rclone/rclone.conf";
    # Deliberately NOT declared in users.users anywhere in this example --
    # proves nixcloud.user is resolved at runtime (via `id`), never at Nix
    # eval time, since eval succeeding here would otherwise be impossible.
    user = "cloudmount";

    accounts = {
      personal = {
        provider = "dropbox";
        # remote omitted -- defaults to the attribute name ("personal").
      };

      work = {
        remote = "work-remote";
        provider = "dropbox";
        fragile = true;
        extraArgs = [ "--vfs-cache-mode=writes" ];
      };
    };

    health = {
      enable = true;
      recovery = "recover";
    };
  };
}
