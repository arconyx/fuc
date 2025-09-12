{
  stdenv,
  lib,
  gleam,
  erlang,
  beamMinimalPackages,
  makeWrapper,
}:
let
  inherit (beamMinimalPackages)
    rebar3WithPlugins
    fetchHex
    ;

  project = lib.importTOML ./gleam.toml;
  manifest = lib.importTOML ./manifest.toml;

  depToHex =
    a:
    fetchHex {
      pkg = a.name;
      version = a.version;
      sha256 = a.outer_checksum;
    };

  pkgs-toml = ''
    [packages]
    ${lib.concatLines (builtins.map (p: ''${p.name} = "${p.version}"'') manifest.packages)}
  '';
in
stdenv.mkDerivation {
  pname = project.name;
  version = project.version;

  src = builtins.path {
    path = ./.;
    name = project.name;
  };

  nativeBuildInputs = [
    gleam
    erlang
    makeWrapper
    (rebar3WithPlugins {
      plugins = with beamMinimalPackages; [ pc ];
    })
  ];

  configurePhase = ''
    runHook preConfigure

    mkdir -p build/packages

    cat <<EOF > build/packages/packages.toml
  ''
  + pkgs-toml
  + ''
    EOF
  ''
  + lib.concatLines (
    builtins.map (
      a: "cp -r --no-preserve=mode --dereference ${depToHex a} build/packages/${a.name}"
    ) manifest.packages
  )
  + ''

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export REBAR_CACHE_DIR="$TMP/rebar-cache"
    gleam export erlang-shipment
          
    runHook postBuild
  '';

  # This recompiles the entire thing to run the tests, making it useless
  # We want to test the shipment, somehow
  # doCheck = true;
  # checkPhase = ''
  #   runHook preCheck
  #   gleam test
  #   runHook postCheck
  # '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{bin,gleam}
    cp -r build/erlang-shipment $out/gleam/${project.name}
    ls $out/gleam/${project.name}
    makeWrapper $out/gleam/${project.name}/entrypoint.sh $out/bin/${project.name} \
    --add-flags run \
    --prefix PATH : ${erlang}/bin

    runHook postInstall
  '';

}
