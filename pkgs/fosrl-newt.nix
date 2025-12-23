{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "newt";
  version = "1.8.0";

  src = fetchFromGitHub {
    owner = "fosrl";
    repo = "newt";
    tag = version;
    hash = "sha256-vvm1KHEuAxiAIySJya2UE2IhIZXSTnYXOY+bJ0eFAxg=";
  };

  vendorHash = "sha256-5Xr6mwPtsqEliKeKv2rhhp6JC7u3coP4nnhIxGMqccU=";

  ldflags = [
    "-s"
    "-w"
    "-X=main.newtVersion=${version}"
  ];

  meta = {
    description = "Tunneling client for Pangolin";
    homepage = "https://github.com/fosrl/newt";
    changelog = "https://github.com/fosrl/newt/releases/tag/${src.tag}";
    license = lib.licenses.agpl3Only;
    maintainers = with lib.maintainers; [];
    mainProgram = "newt";
  };
}
