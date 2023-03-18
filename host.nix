env@{
  GIT_COMMIT_HASH ? ""
,  OP_ENERGY_REPO_LOCATION ? /etc/nixos/.git/modules/overlays/op-energy
  # import psk from out-of-git file
  # TODO: switch to secrets-manager and change to make it more secure
, bitcoind-signet-rpc-psk ? builtins.readFile ( "/etc/nixos/private/bitcoind-signet-rpc-psk.txt")
  # TODO: refactor to autogenerate HMAC from the password above
, bitcoind-signet-rpc-pskhmac ? builtins.readFile ( "/etc/nixos/private/bitcoind-signet-rpc-pskhmac.txt")
, op-energy-db-psk-signet ? builtins.readFile ( "/etc/nixos/private/op-energy-db-psk-signet.txt")
, op-energy-db-salt-signet ? builtins.readFile ( "/etc/nixos/private/op-energy-db-salt-signet.txt")
, bitcoind-mainnet-rpc-psk ? builtins.readFile ( "/etc/nixos/private/bitcoind-mainnet-rpc-psk.txt")
, bitcoind-mainnet-rpc-pskhmac ? builtins.readFile ( "/etc/nixos/private/bitcoind-mainnet-rpc-pskhmac.txt")
, op-energy-db-psk-mainnet ? builtins.readFile ( "/etc/nixos/private/op-energy-db-psk-mainnet.txt")
, op-energy-db-salt-mainnet ? builtins.readFile ( "/etc/nixos/private/op-energy-db-salt-mainnet.txt")
, mainnet_node_ssh_tunnel ? true # by default we want ssh tunnel to main node, but this is useless for github actions as they are using only signet node
}:
{pkgs, lib, ...}:
let
  sourceWithGit = pkgs.copyPathToStore OP_ENERGY_REPO_LOCATION;
  GIT_COMMIT_HASH = if builtins.hasAttr "GIT_COMMIT_HASH" env
    then env.GIT_COMMIT_HASH
    else builtins.readFile ( # if git commit is empty, then try to get it from git
      pkgs.runCommand "get-rev1" {
        nativeBuildInputs = [ pkgs.git ];
      } ''
        echo "OP_ENERGY_REPO_LOCATION = ${OP_ENERGY_REPO_LOCATION}"
        HASH=$(cat ${sourceWithGit}/HEAD | cut -c 1-8 | tr -d '\n' || printf 'NOT A GIT REPO')
        printf $HASH > $out
      ''
    );
  opEnergyModule = import ./overlays/op-energy/nix/module.nix { GIT_COMMIT_HASH = GIT_COMMIT_HASH; };
in
{
  imports = [
    # module, which enables automatic update of the configuration from git
    ./auto-apply-config.nix
    # custom module for op-energy
    opEnergyModule
  ];
  system.stateVersion = "22.05";
  # op-energy part
  services.op-energy-backend = {
    mainnet =
      let
        db = "openergy";
        block_spans_db_name = "${db}_block_spans";
      in {
      db_user = "openergy";
      db_name = db;
      account_db_name = "${db}acc";
      block_spans_db_name = block_spans_db_name;
      db_psk = op-energy-db-psk-mainnet;
      config = ''
        {
          "MEMPOOL": {
            "NETWORK": "mainnet",
            "BACKEND": "none",
            "HTTP_PORT": 8999,
            "API_URL_PREFIX": "/api/v1/",
            "BLOCKS_SUMMARIES_INDEXING": false,
            "INDEXING_BLOCKS_AMOUNT": 0,
            "POLL_RATE_MS": 2000
          },
          "CORE_RPC": {
            "USERNAME": "op-energy",
            "PASSWORD": "${bitcoind-mainnet-rpc-psk}"
          },
          "DATABASE": {
            "ENABLED": true,
            "HOST": "127.0.0.1",
            "PORT": 3306,
            "DATABASE": "${db}",
            "ACCOUNT_DATABASE": "${db}acc",
            "OP_ENERGY_BLOCKCHAIN_DATABASE": "${block_spans_db_name}",
            "USERNAME": "openergy",
            "PASSWORD": "${op-energy-db-psk-mainnet}",
            "SECRET_SALT": "${op-energy-db-salt-mainnet}"
          },
          "STATISTICS": {
            "ENABLED": true,
            "TX_PER_SECOND_SAMPLE_PERIOD": 150
          }
        }
      '';
    };
  };
  # enable op-energy-frontend service
  services.op-energy-frontend = {
    enable = true;
  };

  # bitcoind mainnet instance
  services.bitcoind.mainnet = {
    enable = true;
    dataDir = "/mnt/bitcoind-mainnet";
    extraConfig = ''
      txindex = 1
      server=1
      listen=1
      discover=1
      rpcallowip=127.0.0.1
      # those option affects memory footprint of the instance, so changing the default value
      # will affect the ability to shrink the node's resources.
      # default value is 450 MiB
      # dbcache=3700
      # default value is 125, affects RAM occupation
      # maxconnections=1337
    '';
    rpc.users = {
      op-energy = {
        name = "op-energy";
        passwordHMAC = "${bitcoind-mainnet-rpc-pskhmac}";
      };
    };
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    screen
    atop # process monitor
    tcpdump # traffic sniffer
    iftop # network usage monitor
    git
  ];
  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Open ports in the firewall.
  networking.firewall.allowedTCPPorts = [
    22
    80
  ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  networking.firewall.enable = true;
  networking.firewall.logRefusedConnections = false; # we are not interested in a logs of refused connections
}
