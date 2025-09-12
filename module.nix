{
  pkgs,
  lib,
  config,
  ...
}:
{
  options.services.fuc = {
    enable = lib.mkEnableOption "Enable the Fic Update Collator";
    address = lib.mkOption {
      type = lib.types.str;
      description = "Public facing address for the site, including protocol, port and subfolder.";
      example = "https://thehivemind.gay:3000/fuq";
    };
    port = lib.mkOption {
      type = lib.types.port;
      description = "Port that fuc listens on";
      example = 8000;
      default = 8192;
    };
    credentialsFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to credentials file, in .env style format.

        Must contain:
        - `FUC_OAUTH_CLIENT_ID` and `FUC_OAUTH_CLIENT_SECRET` for Gmail API Oauth.
        - `FUC_SECRET_KEY`: a random string of at least 64 bytes used for cookie signing.
        - `FUC_AO3_LABEL`: ID of gmail label marking emails to process.

        This is read by systemd so it needs to be readable by root, but not by the `fuc`
        user (which is dynamic anyway).
      '';
      example = "/etc/fuc/creds.env";
    };
  };

  config =
    let
      cfg = config.services.fuc;
      internal_port = "98124";
    in
    lib.mkIf cfg.enable {
      systemd.services =
        let
          fuc = pkgs.callPackage ./package.nix { };
        in
        {
          fuc = {
            enable = true;
            description = "Fic update collator";
            requires = [ "network-online.target" ];
            after = [ "network-online.target" ];

            confinement.enable = true;

            serviceConfig = {
              ExecStart = "${fuc}/bin/fuc";

              DynamicUser = true;
              CapabilityBoundingSet = "";
              StateDirectory = "fuc";
              LoadCredential = "fuc.env:${cfg.credentialsFile}";
            };

            environment = {
              FUC_ADDRESS = cfg.address;
              FUC_PORT = internal_port;
              # Don't need FUC_DATABASE_PATH because we have special systemd handling to read STATE_DIRECTORY
            };
          };

          proxy-fuc = {
            enable = true;
            description = "Socket activation proxy for the Fic Update Collator";
            requires = [
              "fuc.service"
              "proxy-fuc.socket"
            ];
            after = [
              "fuc.service"
              "proxy-fuc.socket"
            ];

            serviceConfig = {
              Type = "notify";
              ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd localhost:${internal_port} --exit-idle-time 600";
              PrivateTmp = true;
              PrivateNetwork = true;
            };
          };

        };

      systemd.sockets.proxy-fuc = {
        enable = true;
        description = "Public socket for the Fic Update Collator";
        listenStreams = [ "127.0.0.1:${builtins.toString cfg.port}" ];
        wantedBy = [ "sockets.target" ];
      };
    };
}
