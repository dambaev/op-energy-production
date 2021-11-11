{ config, pkgs, lib, ... }@args:

let
  nixos_apply_script = pkgs.writeScriptBin "nixos_apply_script" ''
    #!${pkgs.stdenv.shell} -e


    cd /etc/nixos
    git reset --hard --recurse-submodules || true # remove local changes to not to conflict
    git pull | grep "Already up to date." > /dev/null || {
      git submodule init || true # in case of first run
      git submodule update --remote # don't force the support to update every repo
    }
    /run/current-system/sw/bin/systemctl start nixos-upgrade --no-block
  '';
  local_git_ssh_command = # here we want to check the GIT_SSH_COMMAND presence in local settings and use it for fetching config updates
    if lib.hasAttrByPath [ "environment" "variables" "GIT_SSH_COMMAND" ] config 
    then config.environment.variables.GIT_SSH_COMMAND
    else "";
in
{
  environment.systemPackages = with pkgs; [ git coreutils nix ];
  # here we are creating new systemd service, that will perform periodical `git pull`
  # inside /etc/nixos directory in order to update system configuration.
  # updated configuration will be applied by periodical system.autoUpgrade
  systemd.services.nixos-apply = {
    description = "keep /etc/nixos state in sync";
    serviceConfig.Type = "oneshot";
    path = [ pkgs.git pkgs.coreutils nixos_apply_script pkgs.nix pkgs.openssh pkgs.connect];
    script =
        ''
        #!${pkgs.stdenv.shell} -e
        if [ "${local_git_ssh_command}" != "" ]; then
          export GIT_SSH_COMMAND="${local_git_ssh_command}"
        fi
        timeout --foreground 9m nixos_apply_script
        '';
    startAt = "*:0/10"; # run every 10 minutes
  };

  # once in a day, we are killing nixos-upgrade and nixos-apply just to be sure, that there is no some stalled builds running
  systemd.services.nixos-upgrade-stop = {
    description = "stop possibly hanged nixos-upgrade service";
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script =
        ''
        /run/current-system/sw/bin/systemctl stop nixos-apply || true
        /run/current-system/sw/bin/systemctl stop nixos-upgrade || true
        '';
    startAt = "*-*-* 21:59:00"; # run every day at midnight
  };

  # now enable auto upgrade option, that will upgrade system for us
  system.autoUpgrade.enable = true;
  nix.gc = {
    automatic = true; # enable the periodic garbage collecting
    options = "-d --delete-older-than 7d"; # delete everything, older than 1d
  };
}
