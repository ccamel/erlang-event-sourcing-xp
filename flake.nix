{
  description = "Erlang Event Sourcing XP development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { nixpkgs, ... }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.actionlint
              pkgs.bash-language-server
              pkgs.deadnix
              pkgs.erlang_27
              pkgs.git
              pkgs.markdownlint-cli2
              pkgs.marksman
              pkgs.nil
              pkgs.nixfmt
              pkgs.nodejs_22
              pkgs.rebar3
              pkgs.statix
              pkgs.uv
              pkgs.yaml-language-server
            ];

            shellHook = ''
              echo "Erlang Event Sourcing XP development environment loaded"
              echo "Erlang: $(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')"
              echo "rebar3: $(rebar3 version)"
            '';
          };
        }
      );
    };
}
