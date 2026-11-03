{
  self,
  pkgs,
}: let
  record = pkgs.writeText "record.json" ''{"v":2,"hotkey":"cmd_space","suggest":true,"at":100,"launches":[],"quicklinks":[]}'';
in
  pkgs.testers.runNixOSTest {
    name = "nanolight-server";
    nodes.server = {
      imports = [self.nixosModules.server];
      services.nanolight-server = {
        enable = true;
        tokensFile = pkgs.writeText "tokens" ''
          # not a secret: a test
          alice:${builtins.hashString "sha256" "alice-token"}
        '';
      };
    };
    testScript = ''
      server.wait_for_unit("nanolight-server.service")
      server.wait_for_open_port(8890)
      server.succeed("curl -sf http://127.0.0.1:8890/healthz")

      code = "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8890/v1/sync"
      assert server.succeed(code) == "401", "no token must be refused"
      assert server.succeed(code + " -H 'Authorization: Bearer wrong'") == "401"
      assert server.succeed(code + " -H 'Authorization: Bearer alice-token'") == "404", "nothing stored yet"

      auth = "-H 'Authorization: Bearer alice-token'"
      server.succeed(f"curl -sf {auth} -X PUT --data @${record} http://127.0.0.1:8890/v1/sync")
      body = server.succeed(f"curl -sf {auth} http://127.0.0.1:8890/v1/sync")
      assert '"hotkey":"cmd_space"' in body, body
      server.succeed("test -s /var/lib/private/nanolight/alice.json")
    '';
  }
